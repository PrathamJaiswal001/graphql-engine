{-# LANGUAGE DerivingStrategies #-}

module Hasura.Server.Auth
  ( getUserInfoWithExpTime,
    AuthMode (..),
    setupAuthMode,
    AdminSecretHash,
    unsafeMkAdminSecretHash,
    hashAdminSecret,
    updateJwkCtx,

    -- * WebHook related
    AuthHookType (..),
    AuthHook (..),

    -- * JWT related
    RawJWT,
    JWTConfig (..),
    JWTCtx (..),
    JWKSet (..),
    processJwt,
    UserAuthentication (..),

    -- * Exposed for testing
    getUserInfoWithExpTime_,
  )
where

import Control.Concurrent.Extended (sleep)
import Control.Monad.Trans.Control (MonadBaseControl)
import Crypto.Hash qualified as Crypto
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.HashSet qualified as Set
import Data.Hashable qualified as Hash
import Data.IORef (newIORef, readIORef)
import Data.List qualified as L
import Data.Text.Encoding qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Hasura.Base.Error
import Hasura.GraphQL.Transport.HTTP.Protocol (ReqsText)
import Hasura.Logging
import Hasura.Prelude
import Hasura.Server.Auth.JWT hiding (processJwt_)
import Hasura.Server.Auth.WebHook
import Hasura.Server.Utils
import Hasura.Session
import Hasura.Tracing qualified as Tracing
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types qualified as HTTP

-- | Typeclass representing the @UserInfo@ authorization and resolving effect
class (Monad m) => UserAuthentication m where
  resolveUserInfo ::
    Logger Hasura ->
    HTTP.Manager ->
    -- | request headers
    [HTTP.Header] ->
    AuthMode ->
    Maybe ReqsText ->
    m (Either QErr (UserInfo, Maybe UTCTime, [HTTP.Header], ExtraUserInfo))

-- | The hashed admin password. 'hashAdminSecret' is our public interface for
-- constructing the secret.
--
-- To prevent misuse and leaking we keep this opaque and don't provide
-- instances that could leak information. Likewise for 'AuthMode'.
--
-- Although this exists only in memory we store only a hash of the admin secret
-- primarily in order to:
--
--     - prevent theoretical timing attacks from a naive `==` check
--     - prevent misuse or inadvertent leaking of the secret
newtype AdminSecretHash = AdminSecretHash (Crypto.Digest Crypto.SHA512)
  deriving (Ord, Eq)

unsafeMkAdminSecretHash :: (Crypto.Digest Crypto.SHA512) -> AdminSecretHash
unsafeMkAdminSecretHash = AdminSecretHash

instance Hash.Hashable AdminSecretHash where
  hashWithSalt salt (AdminSecretHash h) = Hash.hashWithSalt @ByteString salt $ BA.convert h

-- We don't want to be able to leak the secret hash. This is a dummy instance
-- to support 'Show AuthMode' which we want for testing.
instance Show AdminSecretHash where
  show _ = "(error \"AdminSecretHash hidden\")"

hashAdminSecret :: Text -> AdminSecretHash
hashAdminSecret = AdminSecretHash . Crypto.hash . T.encodeUtf8

-- | The methods we'll use to derive roles for authenticating requests.
--
-- @Maybe RoleName@ below is the optionally-defined role for the
-- unauthenticated (anonymous) user.
--
-- See: https://hasura.io/docs/latest/graphql/core/auth/authentication/unauthenticated-access.html
data AuthMode
  = AMNoAuth
  | AMAdminSecret !(Set.HashSet AdminSecretHash) !(Maybe RoleName)
  | AMAdminSecretAndHook !(Set.HashSet AdminSecretHash) !AuthHook
  | AMAdminSecretAndJWT !(Set.HashSet AdminSecretHash) ![JWTCtx] !(Maybe RoleName)
  deriving (Show, Eq)

-- | Validate the user's requested authentication configuration, launching any
-- required maintenance threads for JWT etc.
--
-- This must only be run once, on launch.
setupAuthMode ::
  ( Tracing.HasReporter m,
    MonadError Text m,
    MonadIO m
  ) =>
  Set.HashSet AdminSecretHash ->
  Maybe AuthHook ->
  [JWTConfig] ->
  Maybe RoleName ->
  Logger Hasura ->
  HTTP.Manager ->
  m AuthMode
setupAuthMode adminSecretHashSet mWebHook mJwtSecrets mUnAuthRole logger httpManager =
  case (not (Set.null adminSecretHashSet), mWebHook, not (null mJwtSecrets)) of
    (True, Nothing, False) -> return $ AMAdminSecret adminSecretHashSet mUnAuthRole
    (True, Nothing, True) -> do
      jwtCtxs <- traverse mkJwtCtx (L.nub mJwtSecrets)
      pure $ AMAdminSecretAndJWT adminSecretHashSet jwtCtxs mUnAuthRole
    -- Nothing below this case uses unauth role. Throw a fatal error if we would otherwise ignore
    -- that parameter, lest users misunderstand their auth configuration:
    _
      | isJust mUnAuthRole ->
          throwError $
            "Fatal Error: --unauthorized-role (HASURA_GRAPHQL_UNAUTHORIZED_ROLE)"
              <> requiresAdminScrtMsg
              <> " and is not allowed when --auth-hook (HASURA_GRAPHQL_AUTH_HOOK) is set"
    (False, Nothing, False) -> return AMNoAuth
    (True, Just hook, False) -> return $ AMAdminSecretAndHook adminSecretHashSet hook
    (False, Just _, False) ->
      throwError $
        "Fatal Error : --auth-hook (HASURA_GRAPHQL_AUTH_HOOK)" <> requiresAdminScrtMsg
    (False, Nothing, True) ->
      throwError $
        "Fatal Error : --jwt-secret (HASURA_GRAPHQL_JWT_SECRET)" <> requiresAdminScrtMsg
    (_, Just _, True) ->
      throwError
        "Fatal Error: Both webhook and JWT mode cannot be enabled at the same time"
  where
    requiresAdminScrtMsg =
      " requires --admin-secret (HASURA_GRAPHQL_ADMIN_SECRET) or "
        <> " --access-key (HASURA_GRAPHQL_ACCESS_KEY) to be set"

    mkJwtCtx :: (MonadIO m, MonadError Text m) => JWTConfig -> m JWTCtx
    mkJwtCtx JWTConfig {..} = do
      (jwkUri, jwkKeyConfig) <- case jcKeyOrUrl of
        Left jwk -> do
          jwkRef <- liftIO $ newIORef (JWKSet [jwk], Nothing)
          return (Nothing, jwkRef)
        -- in case JWT url is provided, an empty JWKSet is initialised,
        -- which will be populated by the 'updateJWKCtx' poller thread
        Right uri -> do
          -- fetch JWK initially and throw error if it fails
          void $ liftEitherM $ liftIO $ runExceptT $ withJwkError $ Tracing.runTraceT Tracing.sampleAlways "jwk init" $ fetchJwk logger httpManager uri
          jwkRef <- liftIO $ newIORef (JWKSet [], Nothing)
          return (Just uri, jwkRef)
      let jwtHeader = fromMaybe JHAuthorization jcHeader
      return $ JWTCtx jwkUri jwkKeyConfig jcAudience jcIssuer jcClaims jcAllowedSkew jwtHeader

    withJwkError :: ExceptT JwkFetchError IO (JWKSet, HTTP.ResponseHeaders) -> ExceptT Text IO (JWKSet, HTTP.ResponseHeaders)
    withJwkError act = do
      res <- lift $ runExceptT act
      onLeft res $ \case
        -- when fetching JWK initially, except expiry parsing error, all errors are critical
        JFEHttpException _ msg -> throwError msg
        JFEHttpError _ _ _ e -> throwError e
        JFEJwkParseError _ e -> throwError e
        JFEExpiryParseError _ _ -> pure (JWKSet [], [])

-- | Core logic to fork a poller thread to update the JWK based on the
-- expiry time specified in @Expires@ header or @Cache-Control@ header
updateJwkCtx ::
  (MonadIO m, Tracing.HasReporter m) =>
  AuthMode ->
  HTTP.Manager ->
  Logger Hasura ->
  m Void
updateJwkCtx authMode httpManager logger = forever $ do
  case authMode of
    AMAdminSecretAndJWT _ jwtCtxs _ -> traverse_ updateJwkFromUrl jwtCtxs
    _ -> pure ()
  liftIO $ sleep $ seconds 1
  where
    updateJwkFromUrl ::
      (Tracing.HasReporter m, MonadIO m) =>
      JWTCtx ->
      m ()
    updateJwkFromUrl (JWTCtx url ref _ _ _ _ _) =
      for_ url \uri -> do
        (jwkSet, jwkExpiry) <- liftIO $ readIORef ref
        case jwkSet of
          -- get the JWKs initially if the JWKSet is empty
          JWKSet [] -> fetchAndUpdateJWKs logger httpManager uri ref
          -- if the JWKSet is not empty, get the new JWK based on the
          -- expiry time
          _ -> do
            currentTime <- liftIO getCurrentTime
            for_ jwkExpiry \expiryTime ->
              when (currentTime >= expiryTime) $
                fetchAndUpdateJWKs logger httpManager uri ref

-- | Authenticate the request using the headers and the configured 'AuthMode'.
getUserInfoWithExpTime ::
  forall m.
  (MonadIO m, MonadBaseControl IO m, MonadError QErr m, Tracing.MonadTrace m) =>
  Logger Hasura ->
  HTTP.Manager ->
  [HTTP.Header] ->
  AuthMode ->
  Maybe ReqsText ->
  m (UserInfo, Maybe UTCTime, [HTTP.Header])
getUserInfoWithExpTime = getUserInfoWithExpTime_ userInfoFromAuthHook processJwt

-- Broken out for testing with mocks:
getUserInfoWithExpTime_ ::
  forall m mgr logger.
  (MonadIO m, MonadError QErr m) =>
  -- | mock 'userInfoFromAuthHook'
  ( logger ->
    mgr ->
    AuthHook ->
    [HTTP.Header] ->
    Maybe ReqsText ->
    m (UserInfo, Maybe UTCTime, [HTTP.Header])
  ) ->
  -- | mock 'processJwt'
  ( [JWTCtx] ->
    [HTTP.Header] ->
    Maybe RoleName ->
    m (UserInfo, Maybe UTCTime, [HTTP.Header])
  ) ->
  logger ->
  mgr ->
  [HTTP.Header] ->
  AuthMode ->
  Maybe ReqsText ->
  m (UserInfo, Maybe UTCTime, [HTTP.Header])
getUserInfoWithExpTime_ userInfoFromAuthHook_ processJwt_ logger manager rawHeaders authMode reqs = case authMode of
  AMNoAuth -> withNoExpTime $ mkUserInfoFallbackAdminRole UAuthNotSet
  -- If hasura was started with an admin secret we:
  --   - check if a secret was sent in the request
  --     - if so, check it and authorize as admin else fail
  --   - if not proceed with either webhook or JWT auth if configured
  AMAdminSecret adminSecretHashSet maybeUnauthRole ->
    checkingSecretIfSent adminSecretHashSet $
      withNoExpTime
        -- Consider unauthorized role, if not found raise admin secret header required exception
        case maybeUnauthRole of
          Nothing ->
            throw401 $
              adminSecretHeader
                <> "/"
                <> deprecatedAccessKeyHeader
                <> " required, but not found"
          Just unAuthRole ->
            mkUserInfo (URBPreDetermined unAuthRole) UAdminSecretNotSent sessionVariables
  -- this is the case that actually ends up consuming the request AST
  AMAdminSecretAndHook adminSecretHashSet hook ->
    checkingSecretIfSent adminSecretHashSet $ userInfoFromAuthHook_ logger manager hook rawHeaders reqs
  AMAdminSecretAndJWT adminSecretHashSet jwtSecrets unAuthRole ->
    checkingSecretIfSent adminSecretHashSet $ processJwt_ jwtSecrets rawHeaders unAuthRole
  where
    -- CAREFUL!:
    mkUserInfoFallbackAdminRole adminSecretState =
      mkUserInfo
        (URBFromSessionVariablesFallback adminRoleName)
        adminSecretState
        sessionVariables

    sessionVariables = mkSessionVariablesHeaders rawHeaders

    checkingSecretIfSent ::
      Set.HashSet AdminSecretHash -> m (UserInfo, Maybe UTCTime, [HTTP.Header]) -> m (UserInfo, Maybe UTCTime, [HTTP.Header])
    checkingSecretIfSent adminSecretHashSet actionIfNoAdminSecret = do
      let maybeRequestAdminSecret =
            foldl1 (<|>) $
              map
                (`getSessionVariableValue` sessionVariables)
                [adminSecretHeader, deprecatedAccessKeyHeader]

      -- when admin secret is absent, run the action to retrieve UserInfo
      case maybeRequestAdminSecret of
        Nothing -> actionIfNoAdminSecret
        Just requestAdminSecret -> do
          unless (Set.member (hashAdminSecret requestAdminSecret) adminSecretHashSet) $
            throw401 $
              "invalid " <> adminSecretHeader <> "/" <> deprecatedAccessKeyHeader
          withNoExpTime $ mkUserInfoFallbackAdminRole UAdminSecretSent

    withNoExpTime a = (,Nothing,[]) <$> a
