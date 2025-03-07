{-# LANGUAGE UndecidableInstances #-}

-- | Postgres Types Update
--
-- This module defines the Update-related IR types specific to Postgres.
module Hasura.Backends.Postgres.Types.Update
  ( BackendUpdate (..),
    isEmpty,
    UpdateOpExpression (..),
    MultiRowUpdate (..),
  )
where

import Data.HashMap.Strict qualified as Map
import Data.Monoid (All (..))
import Data.Typeable (Typeable)
import Hasura.Backends.Postgres.SQL.Types (PGCol)
import Hasura.Prelude
import Hasura.RQL.IR.BoolExp (AnnBoolExp, AnnBoolExpFld)
import Hasura.RQL.Types.Backend (Backend)
import Hasura.SQL.Backend (BackendType (Postgres))

-- | Represents an entry in an /update_table_many/ update.
data MultiRowUpdate pgKind v = MultiRowUpdate
  { -- | The /where/ clause for each individual update.
    --
    -- Note that the /single/ updates do not have a where clause, because it
    -- uses the one found in 'Hasura.RQL.IR.Update.AnnotatedUpdateG'. However,
    -- we have one for each update for /update_many/.
    mruWhere :: AnnBoolExp ('Postgres pgKind) v,
    -- | The /update/ expression, e.g, "set", "inc", etc., for each column.
    mruExpression :: HashMap PGCol (UpdateOpExpression v)
  }
  deriving stock (Generic)

deriving instance Backend ('Postgres pgKind) => Functor (MultiRowUpdate pgKind)

deriving instance Backend ('Postgres pgKind) => Foldable (MultiRowUpdate pgKind)

deriving instance Backend ('Postgres pgKind) => Traversable (MultiRowUpdate pgKind)

deriving instance
  ( Data v,
    Typeable pgKind,
    Data (AnnBoolExpFld ('Postgres pgKind) v),
    Backend ('Postgres pgKind)
  ) =>
  Data (MultiRowUpdate pgKind v)

deriving instance
  ( Show (AnnBoolExpFld ('Postgres pgKind) v),
    Show (UpdateOpExpression v),
    Backend ('Postgres pgKind)
  ) =>
  Show (MultiRowUpdate pgKind v)

deriving instance
  ( Eq (AnnBoolExpFld ('Postgres pgKind) v),
    Eq (UpdateOpExpression v),
    Backend ('Postgres pgKind)
  ) =>
  Eq (MultiRowUpdate pgKind v)

-- | The PostgreSQL-specific data of an Update expression.
--
-- This is parameterised over @v@ which enables different phases of IR
-- transformation to maintain the overall structure while enriching/transforming
-- the data at the leaves.
data BackendUpdate pgKind v
  = -- | The update operations to perform on each colum.
    BackendUpdate (HashMap PGCol (UpdateOpExpression v))
  | -- | The update operations to perform, in sequence, for an
    -- /update_table_many/ operation.
    BackendMultiRowUpdate [MultiRowUpdate pgKind v]
  deriving stock (Generic)

deriving instance Backend ('Postgres pgKind) => Functor (BackendUpdate pgKind)

deriving instance Backend ('Postgres pgKind) => Foldable (BackendUpdate pgKind)

deriving instance Backend ('Postgres pgKind) => Traversable (BackendUpdate pgKind)

deriving instance
  ( Data v,
    Typeable pgKind,
    Data (AnnBoolExpFld ('Postgres pgKind) v),
    Backend ('Postgres pgKind)
  ) =>
  Data (BackendUpdate pgKind v)

deriving instance
  ( Backend ('Postgres pgKind),
    Show (MultiRowUpdate pgKind v),
    Show (UpdateOpExpression v)
  ) =>
  Show (BackendUpdate pgKind v)

deriving instance
  ( Backend ('Postgres pgKind),
    Eq (MultiRowUpdate pgKind v),
    Eq (UpdateOpExpression v)
  ) =>
  Eq (BackendUpdate pgKind v)

-- | Are we updating anything?
isEmpty :: BackendUpdate pgKind v -> Bool
isEmpty =
  \case
    BackendUpdate hm ->
      Map.null hm
    BackendMultiRowUpdate xs ->
      getAll $ foldMap (All . Map.null . mruExpression) xs

-- | The various @update operators@ supported by PostgreSQL,
-- i.e. the @_set@, @_inc@ operators that appear in the schema.
--
-- See <https://hasura.io/docs/latest/graphql/core/databases/postgres/mutations/update.html#postgres-update-mutation Update Mutations User docs>
data UpdateOpExpression v
  = UpdateSet v
  | UpdateInc v
  | UpdateAppend v
  | UpdatePrepend v
  | UpdateDeleteKey v
  | UpdateDeleteElem v
  | UpdateDeleteAtPath [v]
  deriving (Functor, Foldable, Traversable, Generic, Data, Show, Eq)
