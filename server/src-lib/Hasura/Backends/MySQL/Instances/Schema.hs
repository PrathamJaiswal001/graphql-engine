{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Hasura.Backends.MySQL.Instances.Schema () where

import Data.ByteString (ByteString)
import Data.HashMap.Strict qualified as HM
import Data.List.NonEmpty qualified as NE
import Data.Text.Encoding (encodeUtf8)
import Data.Text.Extended
import Database.MySQL.Base.Types qualified as MySQL
import Hasura.Backends.MySQL.Types qualified as MySQL
import Hasura.Base.Error
import Hasura.Base.ErrorMessage (toErrorMessage)
import Hasura.GraphQL.Schema.Backend
import Hasura.GraphQL.Schema.Build qualified as GSB
import Hasura.GraphQL.Schema.Common
import Hasura.GraphQL.Schema.NamingCase
import Hasura.GraphQL.Schema.Parser
  ( InputFieldsParser,
    Kind (..),
    MonadParse,
    Parser,
  )
import Hasura.GraphQL.Schema.Parser qualified as P
import Hasura.GraphQL.Schema.Select
import Hasura.Name qualified as Name
import Hasura.Prelude
import Hasura.RQL.IR
import Hasura.RQL.IR.Select qualified as IR
import Hasura.RQL.Types.Backend as RQL
import Hasura.RQL.Types.Column as RQL
import Hasura.RQL.Types.SchemaCache as RQL
import Hasura.SQL.Backend
import Language.GraphQL.Draft.Syntax qualified as GQL

instance BackendSchema 'MySQL where
  buildTableQueryAndSubscriptionFields = GSB.buildTableQueryAndSubscriptionFields
  buildTableRelayQueryFields _ _ _ _ _ = pure []
  buildTableStreamingSubscriptionFields = GSB.buildTableStreamingSubscriptionFields
  buildTableInsertMutationFields _ _ _ _ _ = pure []
  buildTableUpdateMutationFields _ _ _ _ _ = pure []
  buildTableDeleteMutationFields _ _ _ _ _ = pure []
  buildFunctionQueryFields _ _ _ _ = pure []
  buildFunctionRelayQueryFields _ _ _ _ _ = pure []
  buildFunctionMutationFields _ _ _ _ = pure []
  relayExtension = Nothing
  nodesAggExtension = Just ()
  streamSubscriptionExtension = Nothing
  columnParser = columnParser'
  enumParser = enumParser'
  possiblyNullable = possiblyNullable'
  scalarSelectionArgumentsParser _ = pure Nothing
  orderByOperators _sourceInfo = orderByOperators'
  comparisonExps = comparisonExps'
  countTypeInput = mysqlCountTypeInput
  aggregateOrderByCountType = error "aggregateOrderByCountType: MySQL backend does not support this operation yet."
  computedField = error "computedField: MySQL backend does not support this operation yet."

instance BackendTableSelectSchema 'MySQL where
  tableArguments = mysqlTableArgs
  selectTable = defaultSelectTable
  selectTableAggregate = defaultSelectTableAggregate
  tableSelectionSet = defaultTableSelectionSet

mysqlTableArgs ::
  forall r m n.
  MonadBuildSchema 'MySQL r m n =>
  TableInfo 'MySQL ->
  SchemaT r m (InputFieldsParser n (IR.SelectArgsG 'MySQL (UnpreparedValue 'MySQL)))
mysqlTableArgs tableInfo = do
  whereParser <- tableWhereArg tableInfo
  orderByParser <- tableOrderByArg tableInfo
  pure do
    whereArg <- whereParser
    orderByArg <- orderByParser
    limitArg <- tableLimitArg
    offsetArg <- tableOffsetArg
    pure $
      IR.SelectArgs
        { IR._saWhere = whereArg,
          IR._saOrderBy = orderByArg,
          IR._saLimit = limitArg,
          IR._saOffset = offsetArg,
          IR._saDistinct = Nothing
        }

bsParser :: MonadParse m => Parser 'Both m ByteString
bsParser = encodeUtf8 <$> P.string

columnParser' ::
  MonadBuildSchema 'MySQL r m n =>
  ColumnType 'MySQL ->
  GQL.Nullability ->
  SchemaT r m (Parser 'Both n (ValueWithOrigin (ColumnValue 'MySQL)))
columnParser' columnType nullability = case columnType of
  ColumnScalar scalarType ->
    P.memoizeOn 'columnParser' (scalarType, nullability) $
      peelWithOrigin . fmap (ColumnValue columnType) . possiblyNullable' scalarType nullability
        <$> case scalarType of
          MySQL.Decimal -> pure $ MySQL.DecimalValue <$> P.float
          MySQL.Tiny -> pure $ MySQL.TinyValue <$> P.int
          MySQL.Short -> pure $ MySQL.SmallValue <$> P.int
          MySQL.Long -> pure $ MySQL.IntValue <$> P.int
          MySQL.Float -> pure $ MySQL.FloatValue <$> P.float
          MySQL.Double -> pure $ MySQL.DoubleValue <$> P.float
          MySQL.Null -> pure $ MySQL.NullValue <$ P.string
          MySQL.LongLong -> pure $ MySQL.BigValue <$> P.int
          MySQL.Int24 -> pure $ MySQL.MediumValue <$> P.int
          MySQL.Date -> pure $ MySQL.DateValue <$> P.string
          MySQL.Year -> pure $ MySQL.YearValue <$> P.string
          MySQL.Bit -> pure $ MySQL.BitValue <$> P.boolean
          MySQL.String -> pure $ MySQL.VarcharValue <$> P.string
          MySQL.VarChar -> pure $ MySQL.VarcharValue <$> P.string
          MySQL.DateTime -> pure $ MySQL.DatetimeValue <$> P.string
          MySQL.Blob -> pure $ MySQL.BlobValue <$> bsParser
          MySQL.Timestamp -> pure $ MySQL.TimestampValue <$> P.string
          _ -> do
            name <- MySQL.mkMySQLScalarTypeName scalarType
            let schemaType = P.TNamed P.NonNullable $ P.Definition name Nothing Nothing [] P.TIScalar
            pure $
              P.Parser
                { pType = schemaType,
                  pParser =
                    P.valueToJSON (P.toGraphQLType schemaType)
                      >=> either (P.parseErrorWith P.ParseFailed . toErrorMessage . qeError) pure . (MySQL.parseScalarValue scalarType)
                }
  ColumnEnumReference (EnumReference tableName enumValues customTableName) ->
    case nonEmpty (HM.toList enumValues) of
      Just enumValuesList ->
        peelWithOrigin . fmap (ColumnValue columnType)
          <$> enumParser' tableName enumValuesList customTableName nullability
      Nothing -> throw400 ValidationFailed "empty enum values"

enumParser' ::
  MonadBuildSchema 'MySQL r m n =>
  TableName 'MySQL ->
  NonEmpty (EnumValue, EnumValueInfo) ->
  Maybe GQL.Name ->
  GQL.Nullability ->
  SchemaT r m (Parser 'Both n (ScalarValue 'MySQL))
enumParser' tableName enumValues customTableName nullability = do
  enumName <- mkEnumTypeName @'MySQL tableName customTableName
  pure $ possiblyNullable' MySQL.VarChar nullability $ P.enum enumName Nothing (mkEnumValue <$> enumValues)
  where
    mkEnumValue :: (EnumValue, EnumValueInfo) -> (P.Definition P.EnumValueInfo, RQL.ScalarValue 'MySQL)
    mkEnumValue (RQL.EnumValue value, EnumValueInfo description) =
      ( P.Definition value (GQL.Description <$> description) Nothing [] P.EnumValueInfo,
        MySQL.VarcharValue $ GQL.unName value
      )

possiblyNullable' ::
  (MonadParse m) =>
  ScalarType 'MySQL ->
  GQL.Nullability ->
  Parser 'Both m (ScalarValue 'MySQL) ->
  Parser 'Both m (ScalarValue 'MySQL)
possiblyNullable' _scalarType (GQL.Nullability isNullable)
  | isNullable = fmap (fromMaybe MySQL.NullValue) . P.nullable
  | otherwise = id

orderByOperators' :: NamingCase -> (GQL.Name, NonEmpty (P.Definition P.EnumValueInfo, (BasicOrderType 'MySQL, NullsOrderType 'MySQL)))
orderByOperators' _tCase =
  (Name._order_by,) $
    -- NOTE: NamingCase is not being used here as we don't support naming conventions for this DB
    NE.fromList
      [ ( define Name._asc "in ascending order, nulls first",
          (MySQL.Asc, MySQL.NullsFirst)
        ),
        ( define Name._asc_nulls_first "in ascending order, nulls first",
          (MySQL.Asc, MySQL.NullsFirst)
        ),
        ( define Name._asc_nulls_last "in ascending order, nulls last",
          (MySQL.Asc, MySQL.NullsLast)
        ),
        ( define Name._desc "in descending order, nulls last",
          (MySQL.Desc, MySQL.NullsLast)
        ),
        ( define Name._desc_nulls_first "in descending order, nulls first",
          (MySQL.Desc, MySQL.NullsFirst)
        ),
        ( define Name._desc_nulls_last "in descending order, nulls last",
          (MySQL.Desc, MySQL.NullsLast)
        )
      ]
  where
    define name desc = P.Definition name (Just desc) Nothing [] P.EnumValueInfo

-- | TODO: Make this as thorough as the one for MSSQL/PostgreSQL
comparisonExps' ::
  forall m n r.
  MonadBuildSchema 'MySQL r m n =>
  ColumnType 'MySQL ->
  SchemaT r m (Parser 'Input n [ComparisonExp 'MySQL])
comparisonExps' = P.memoize 'comparisonExps $ \columnType -> do
  -- see Note [Columns in comparison expression are never nullable]
  typedParser <- columnParser columnType (GQL.Nullability False)
  let name = P.getName typedParser <> Name.__MySQL_comparison_exp
      desc =
        GQL.Description $
          "Boolean expression to compare columns of type "
            <> P.getName typedParser
              <<> ". All fields are combined with logical 'AND'."
  pure $
    P.object name (Just desc) $
      catMaybes
        <$> sequenceA
          [ P.fieldOptional Name.__is_null Nothing (bool ANISNOTNULL ANISNULL <$> P.boolean),
            P.fieldOptional Name.__eq Nothing (AEQ True . mkParameter <$> typedParser),
            P.fieldOptional Name.__neq Nothing (ANE True . mkParameter <$> typedParser),
            P.fieldOptional Name.__gt Nothing (AGT . mkParameter <$> typedParser),
            P.fieldOptional Name.__lt Nothing (ALT . mkParameter <$> typedParser),
            P.fieldOptional Name.__gte Nothing (AGTE . mkParameter <$> typedParser),
            P.fieldOptional Name.__lte Nothing (ALTE . mkParameter <$> typedParser)
          ]

mysqlCountTypeInput ::
  MonadParse n =>
  Maybe (Parser 'Both n (Column 'MySQL)) ->
  InputFieldsParser n (IR.CountDistinct -> CountType 'MySQL)
mysqlCountTypeInput = \case
  Just columnEnum -> do
    columns <- P.fieldOptional Name._columns Nothing $ P.list columnEnum
    pure $ flip mkCountType columns
  Nothing -> pure $ flip mkCountType Nothing
  where
    mkCountType :: IR.CountDistinct -> Maybe [Column 'MySQL] -> CountType 'MySQL
    mkCountType _ Nothing = MySQL.StarCountable
    mkCountType IR.SelectCountDistinct (Just cols) =
      maybe MySQL.StarCountable MySQL.DistinctCountable $ nonEmpty cols
    mkCountType IR.SelectCountNonDistinct (Just cols) =
      maybe MySQL.StarCountable MySQL.NonNullFieldCountable $ nonEmpty cols
