{-# LANGUAGE TemplateHaskell #-}

-- | Postgres Execute subscription
--
-- Multiplex is an optimization which allows us to group similar queries into a
-- single query, and routing the response rows afterwards. See
-- https://hasura.io/docs/latest/graphql/core/databases/postgres/subscriptions/execution-and-performance.html
-- for more details
--
-- See 'Hasura.Backends.Postgres.Instances.Execute'.
module Hasura.Backends.Postgres.Execute.Subscription
  ( MultiplexedQuery (..),
    QueryParametersInfo (..),
    mkMultiplexedQuery,
    mkStreamingMultiplexedQuery,
    resolveMultiplexedValue,
    validateVariablesTx,
    executeMultiplexedQuery,
    executeStreamingMultiplexedQuery,
    executeQuery,
    SubscriptionType (..),
  )
where

import Control.Lens
import Control.Monad.Writer
import Data.ByteString qualified as B
import Data.HashMap.Strict qualified as HashMap
import Data.HashMap.Strict.InsOrd qualified as InsOrdHashMap
import Data.HashSet qualified as Set
import Data.Semigroup.Generic
import Data.Text.Extended
import Database.PG.Query qualified as PG
import Hasura.Backends.Postgres.Connection
import Hasura.Backends.Postgres.SQL.DML qualified as S
import Hasura.Backends.Postgres.SQL.Error
import Hasura.Backends.Postgres.SQL.Types
import Hasura.Backends.Postgres.SQL.Value
import Hasura.Backends.Postgres.Translate.Column (toTxtValue)
import Hasura.Backends.Postgres.Translate.Select qualified as DS
import Hasura.Backends.Postgres.Translate.Select.Internal.Helpers (customSQLToInnerCTEs, toQuery)
import Hasura.Backends.Postgres.Translate.Types (CustomSQLCTEs (..))
import Hasura.Backends.Postgres.Types.Column
import Hasura.Base.Error
import Hasura.GraphQL.Execute.Subscription.Plan
import Hasura.GraphQL.Parser.Names
import Hasura.Prelude hiding (runWriterT)
import Hasura.RQL.IR
import Hasura.RQL.Types.Backend
import Hasura.RQL.Types.BackendType
import Hasura.RQL.Types.Column
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.Subscription
import Hasura.SQL.Types
import Hasura.Session
import Language.GraphQL.Draft.Syntax qualified as G

----------------------------------------------------------------------------------------------------
-- Variables

subsAlias :: S.TableAlias
subsAlias = S.mkTableAlias "_subs"

subsIdentifier :: TableIdentifier
subsIdentifier = S.tableAliasToIdentifier subsAlias

resultIdAlias, resultVarsAlias :: S.ColumnAlias
resultIdAlias = S.mkColumnAlias "result_id"
resultVarsAlias = S.mkColumnAlias "result_vars"

fldRespAlias :: S.TableAlias
fldRespAlias = S.mkTableAlias "_fld_resp"

fldRespIdentifier :: TableIdentifier
fldRespIdentifier = S.tableAliasToIdentifier fldRespAlias

-- | Internal: Used to collect information about various parameters
-- of a subscription field's AST as we resolve them to SQL expressions.
data QueryParametersInfo (b :: BackendType) = QueryParametersInfo
  { _qpiReusableVariableValues :: HashMap G.Name (ColumnValue b),
    _qpiSyntheticVariableValues :: Seq (ColumnValue b),
    -- | The session variables that are referenced in the query root fld's AST.
    -- This information is used to determine a cohort's required session
    -- variables
    _qpiReferencedSessionVariables :: Set.HashSet SessionVariable
  }
  deriving (Generic)
  deriving (Semigroup, Monoid) via (GenericSemigroupMonoid (QueryParametersInfo b))

makeLenses ''QueryParametersInfo

-- | Checks if the provided arguments are valid values for their corresponding types.
-- | Generates SQL of the format "select 'v1'::t1, 'v2'::t2 ..."
validateVariablesTx ::
  forall pgKind f m.
  (Traversable f, MonadTx m, MonadIO m) =>
  f (ColumnValue ('Postgres pgKind)) ->
  m (ValidatedVariables f)
validateVariablesTx variableValues = do
  -- no need to test the types when there are no variables to test.
  unless (null variableValues) do
    let valSel = mkValidationSel $ toList variableValues
    PG.Discard () <- liftTx $ PG.rawQE dataExnErrHandler (PG.fromBuilder $ toSQL valSel) [] False
    pure ()
  pure . ValidatedVariables $ fmap (txtEncodedVal . cvValue) variableValues
  where
    mkExtr = flip S.Extractor Nothing . toTxtValue
    mkValidationSel vars =
      S.mkSelect {S.selExtr = map mkExtr vars}
    -- Explicitly look for the class of errors raised when the format of a value
    -- provided for a type is incorrect.
    dataExnErrHandler = mkTxErrorHandler (has _PGDataException)

----------------------------------------------------------------------------------------------------
-- Multiplexed queries

newtype MultiplexedQuery = MultiplexedQuery {unMultiplexedQuery :: PG.Query}
  deriving (Eq, Hashable)

instance ToTxt MultiplexedQuery where
  toTxt = PG.getQueryText . unMultiplexedQuery

toSQLFromItem ::
  ( Backend ('Postgres pgKind),
    DS.PostgresTranslateSelect pgKind,
    MonadWriter CustomSQLCTEs m,
    MonadIO m,
    MonadError QErr m
  ) =>
  UserInfo ->
  S.TableAlias ->
  QueryDB ('Postgres pgKind) Void S.SQLExp ->
  m S.FromItem
toSQLFromItem userInfo tableAlias = \case
  QDBSingleRow s -> S.mkSelFromItem <$> DS.mkSQLSelect userInfo JASSingleObject s <*> pure tableAlias
  QDBMultipleRows s -> S.mkSelFromItem <$> DS.mkSQLSelect userInfo JASMultipleRows s <*> pure tableAlias
  QDBAggregation s -> S.mkSelFromItem <$> DS.mkAggregateSelect userInfo s <*> pure tableAlias
  QDBConnection s -> S.mkSelectWithFromItem <$> DS.mkConnectionSelect userInfo s <*> pure tableAlias
  QDBStreamMultipleRows s -> S.mkSelFromItem <$> DS.mkStreamSQLSelect userInfo s <*> pure tableAlias

mkMultiplexedQuery ::
  ( Backend ('Postgres pgKind),
    DS.PostgresTranslateSelect pgKind,
    MonadIO m,
    MonadError QErr m
  ) =>
  UserInfo ->
  InsOrdHashMap.InsOrdHashMap G.Name (QueryDB ('Postgres pgKind) Void S.SQLExp) ->
  m MultiplexedQuery
mkMultiplexedQuery userInfo rootFields = do
  (sqlFrom, customSQLCTEs) <-
    runWriterT
      $ traverse
        ( \(fieldAlias, resolvedAST) ->
            toSQLFromItem userInfo (S.mkTableAlias $ G.unName fieldAlias) resolvedAST
        )
        (InsOrdHashMap.toList rootFields)
  -- multiplexed queries may only contain read only raw queries
  let selectWith = S.SelectWith [] select
      select =
        S.mkSelect
          { S.selExtr =
              -- SELECT _subs.result_id, _fld_resp.root AS result
              [ S.Extractor (mkQualifiedIdentifier subsIdentifier (Identifier "result_id")) Nothing,
                S.Extractor (mkQualifiedIdentifier fldRespIdentifier (Identifier "root")) (Just $ S.toColumnAlias $ Identifier "result")
              ],
            S.selFrom =
              Just
                $ S.FromExp
                  [ S.FIJoin
                      $ S.JoinExpr subsInputFromItem S.LeftOuter responseLateralFromItem (S.JoinOn $ S.BELit True)
                  ]
          }
      -- LEFT OUTER JOIN LATERAL ( ... ) _fld_resp
      responseLateralFromItem = S.mkLateralFromItem selectRootFields fldRespAlias
      selectRootFields =
        S.mkSelect
          { S.selExtr = [S.Extractor rootFieldsJsonAggregate (Just $ S.toColumnAlias $ Identifier "root")],
            S.selCTEs = customSQLToInnerCTEs customSQLCTEs,
            S.selFrom =
              Just $ S.FromExp sqlFrom
          }
  pure $ MultiplexedQuery . toQuery $ selectWith
  where
    -- FROM unnest($1::uuid[], $2::json[]) _subs (result_id, result_vars)
    subsInputFromItem =
      S.FIUnnest
        [S.SEPrep 1 `S.SETyAnn` S.TypeAnn "uuid[]", S.SEPrep 2 `S.SETyAnn` S.TypeAnn "json[]"]
        subsAlias
        [S.toColumnAlias $ Identifier "result_id", S.toColumnAlias $ Identifier "result_vars"]

    -- json_build_object('field1', field1.root, 'field2', field2.root, ...)
    rootFieldsJsonAggregate = S.SEFnApp "json_build_object" rootFieldsJsonPairs Nothing
    rootFieldsJsonPairs = flip concatMap (InsOrdHashMap.keys rootFields) $ \fieldAlias ->
      [ S.SELit (G.unName fieldAlias),
        mkQualifiedIdentifier (aliasToIdentifier fieldAlias) (Identifier "root")
      ]

    mkQualifiedIdentifier prefix = S.SEQIdentifier . S.QIdentifier (S.QualifiedIdentifier prefix Nothing)
    aliasToIdentifier = TableIdentifier . G.unName

mkStreamingMultiplexedQuery ::
  ( Backend ('Postgres pgKind),
    DS.PostgresTranslateSelect pgKind,
    MonadIO m,
    MonadError QErr m
  ) =>
  UserInfo ->
  (G.Name, (QueryDB ('Postgres pgKind) Void S.SQLExp)) ->
  m MultiplexedQuery
mkStreamingMultiplexedQuery userInfo (fieldAlias, resolvedAST) = do
  (fromSQL, customSQLCTEs) <- runWriterT (toSQLFromItem userInfo (S.mkTableAlias $ G.unName fieldAlias) resolvedAST)
  let selectWith = S.SelectWith [] select
      select =
        S.mkSelect
          { S.selExtr =
              -- SELECT _subs.result_id, _fld_resp.root, _fld_resp.cursor AS result
              [ S.Extractor (mkQualifiedIdentifier subsIdentifier (Identifier "result_id")) Nothing,
                S.Extractor (mkQualifiedIdentifier fldRespIdentifier (Identifier "root")) (Just $ S.toColumnAlias $ Identifier "result"),
                S.Extractor (mkQualifiedIdentifier fldRespIdentifier (Identifier "cursor")) (Just $ S.toColumnAlias $ Identifier "cursor")
              ],
            S.selFrom =
              Just
                $ S.FromExp
                  [ S.FIJoin
                      $ S.JoinExpr subsInputFromItem S.LeftOuter responseLateralFromItem (S.JoinOn $ S.BELit True)
                  ]
          }
      -- LEFT OUTER JOIN LATERAL ( ... ) _fld_resp
      responseLateralFromItem = S.mkLateralFromItem selectRootFields fldRespAlias

      selectRootFields =
        S.mkSelect
          { S.selExtr = [(S.Extractor rootFieldJsonAggregate (Just $ S.toColumnAlias $ Identifier "root")), cursorExtractor],
            S.selCTEs = customSQLToInnerCTEs customSQLCTEs,
            S.selFrom =
              Just $ S.FromExp [fromSQL]
          }
  pure $ MultiplexedQuery . toQuery $ selectWith
  where
    -- FROM unnest($1::uuid[], $2::json[]) _subs (result_id, result_vars)
    subsInputFromItem =
      S.FIUnnest
        [S.SEPrep 1 `S.SETyAnn` S.TypeAnn "uuid[]", S.SEPrep 2 `S.SETyAnn` S.TypeAnn "json[]"]
        subsAlias
        [resultIdAlias, resultVarsAlias]

    -- json_build_object('field1', field1.root, 'field2', field2.root, ...)
    rootFieldJsonAggregate = S.SEFnApp "json_build_object" rootFieldJsonPair Nothing
    rootFieldJsonPair =
      [ S.SELit (G.unName fieldAlias),
        mkQualifiedIdentifier (aliasToIdentifier fieldAlias) (Identifier "root")
      ]

    -- to_json("root"."cursor") AS "cursor"
    cursorSQLExp = S.SEFnApp "to_json" [mkQualifiedIdentifier (aliasToIdentifier fieldAlias) (Identifier "cursor")] Nothing
    cursorExtractor = S.Extractor cursorSQLExp (Just $ S.toColumnAlias $ Identifier "cursor")
    mkQualifiedIdentifier prefix = S.SEQIdentifier . S.QIdentifier (S.QualifiedIdentifier prefix Nothing)
    aliasToIdentifier = TableIdentifier . G.unName

-- | Resolves an 'GR.UnresolvedVal' by converting 'GR.UVPG' values to SQL
-- expressions that refer to the @result_vars@ input object, collecting information
-- about various parameters of the query along the way.
resolveMultiplexedValue ::
  ( MonadState (QueryParametersInfo ('Postgres pgKind)) m,
    MonadError QErr m
  ) =>
  SessionVariables ->
  UnpreparedValue ('Postgres pgKind) ->
  m S.SQLExp
resolveMultiplexedValue allSessionVars = \case
  UVParameter provenance colVal -> do
    varJsonPath <- case provenance of
      FromGraphQL varInfo -> do
        let varName = getName varInfo
        modifying qpiReusableVariableValues $ HashMap.insert varName colVal
        pure ["query", G.unName varName]
      _ -> do
        syntheticVarIndex <- use (qpiSyntheticVariableValues . to length)
        modifying qpiSyntheticVariableValues (|> colVal)
        pure ["synthetic", tshow syntheticVarIndex]
    pure $ fromResVars (CollectableTypeScalar $ unsafePGColumnToBackend $ cvType colVal) varJsonPath
  UVSessionVar ty sessVar -> do
    _ <-
      getSessionVariableValue sessVar allSessionVars
        `onNothing` throw400
          NotFound
          ("missing session variable: " <>> sessionVariableToText sessVar)
    modifying qpiReferencedSessionVariables (Set.insert sessVar)
    pure $ fromResVars ty ["session", sessionVariableToText sessVar]
  UVLiteral sqlExp -> pure sqlExp
  UVSession -> do
    -- if the entire session is referenced, then add all session vars in referenced vars
    modifying qpiReferencedSessionVariables (const $ getSessionVariablesSet allSessionVars)
    pure $ fromResVars (CollectableTypeScalar PGJSON) ["session"]
  where
    fromResVars pgType jPath =
      addTypeAnnotation pgType
        $ S.SEOpApp
          (S.SQLOp "#>>")
          [ S.SEQIdentifier $ S.QIdentifier (S.QualifiedIdentifier subsIdentifier Nothing) (Identifier "result_vars"),
            S.SEArray $ map S.SELit jPath
          ]
    addTypeAnnotation pgType =
      flip S.SETyAnn (S.mkTypeAnn pgType) . case pgType of
        CollectableTypeScalar scalarType -> withConstructorFn scalarType
        CollectableTypeArray _ -> id

----------------------------------------------------------------------------------------------------
-- Execution

executeMultiplexedQuery ::
  (MonadTx m) =>
  MultiplexedQuery ->
  [(CohortId, CohortVariables)] ->
  m [(CohortId, B.ByteString)]
executeMultiplexedQuery (MultiplexedQuery query) cohorts =
  executeQuery query cohorts

executeStreamingMultiplexedQuery ::
  (MonadTx m) =>
  MultiplexedQuery ->
  [(CohortId, CohortVariables)] ->
  m [(CohortId, B.ByteString, PG.ViaJSON CursorVariableValues)]
executeStreamingMultiplexedQuery (MultiplexedQuery query) cohorts = do
  executeQuery query cohorts

-- | Internal; used by both 'executeMultiplexedQuery', 'executeStreamingMultiplexedQuery'
-- and 'pgDBSubscriptionExplain'.
executeQuery ::
  (MonadTx m, PG.FromRes a) =>
  PG.Query ->
  [(CohortId, CohortVariables)] ->
  m a
executeQuery query cohorts =
  let (cohortIds, cohortVars) = unzip cohorts
      preparedArgs = (CohortIdArray cohortIds, CohortVariablesArray cohortVars)
   in liftTx $ PG.withQE defaultTxErrorHandler query preparedArgs True
