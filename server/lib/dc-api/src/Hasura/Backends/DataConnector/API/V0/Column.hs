{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TemplateHaskell #-}

module Hasura.Backends.DataConnector.API.V0.Column
  ( ColumnName (..),
    ColumnType (..),
    ColumnInfo (..),
    ciName,
    ciType,
    ciNullable,
    ciDescription,
    ciInsertable,
    ciUpdatable,
    ciValueGenerated,
    ColumnValueGenerationStrategy (..),
  )
where

--------------------------------------------------------------------------------

import Autodocodec
import Autodocodec.OpenAPI ()
import Control.DeepSeq (NFData)
import Control.Lens.TH (makeLenses)
import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import Data.Data (Data)
import Data.HashMap.Strict qualified as HashMap
import Data.Hashable (Hashable)
import Data.OpenApi (ToSchema)
import Data.Text (Text)
import GHC.Generics (Generic)
import Hasura.Backends.DataConnector.API.V0.Scalar qualified as API.V0.Scalar
import Language.GraphQL.Draft.Syntax qualified as G
import Prelude

--------------------------------------------------------------------------------

newtype ColumnName = ColumnName {unColumnName :: Text}
  deriving stock (Eq, Ord, Show, Generic, Data)
  deriving anyclass (NFData, Hashable)
  deriving newtype (ToJSONKey, FromJSONKey)
  deriving (FromJSON, ToJSON, ToSchema) via Autodocodec ColumnName

instance HasCodec ColumnName where
  codec = dimapCodec ColumnName unColumnName textCodec

--------------------------------------------------------------------------------

data ColumnType
  = ColumnTypeScalar API.V0.Scalar.ScalarType
  | ColumnTypeObject G.Name
  | ColumnTypeArray ColumnType Bool
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (NFData, Hashable)
  deriving (FromJSON, ToJSON, ToSchema) via Autodocodec ColumnType

instance HasCodec ColumnType where
  codec =
    named "ColumnType" $
      matchChoiceCodec
        (dimapCodec ColumnTypeScalar id codec)
        (object "ColumnTypeNonScalar" $ discriminatedUnionCodec "type" enc dec)
        \case
          ColumnTypeScalar scalar -> Left scalar
          ct -> Right ct
    where
      enc = \case
        ColumnTypeScalar _ -> error "unexpected ColumnTypeScalar"
        ColumnTypeObject objectName -> ("object", mapToEncoder objectName columnTypeObjectCodec)
        ColumnTypeArray columnType isNullable -> ("array", mapToEncoder (columnType, isNullable) columnTypeArrayCodec)
      dec =
        HashMap.fromList
          [ ("object", ("ColumnTypeObject", mapToDecoder ColumnTypeObject columnTypeObjectCodec)),
            ("array", ("ColumnTypeArray", mapToDecoder (uncurry ColumnTypeArray) columnTypeArrayCodec))
          ]
      columnTypeObjectCodec = requiredField' "name"
      columnTypeArrayCodec = (,) <$> requiredField' "element_type" .= fst <*> requiredField' "nullable" .= snd

--------------------------------------------------------------------------------

data ColumnInfo = ColumnInfo
  { _ciName :: ColumnName,
    _ciType :: ColumnType,
    _ciNullable :: Bool,
    _ciDescription :: Maybe Text,
    _ciInsertable :: Bool,
    _ciUpdatable :: Bool,
    _ciValueGenerated :: Maybe ColumnValueGenerationStrategy
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (NFData, Hashable)
  deriving (FromJSON, ToJSON, ToSchema) via Autodocodec ColumnInfo

instance HasCodec ColumnInfo where
  codec =
    object "ColumnInfo" $
      ColumnInfo
        <$> requiredField "name" "Column name" .= _ciName
        <*> requiredField "type" "Column type" .= _ciType
        <*> requiredField "nullable" "Is column nullable" .= _ciNullable
        <*> optionalFieldOrNull "description" "Column description" .= _ciDescription
        <*> optionalFieldWithDefault "insertable" False "Whether or not the column can be inserted into" .= _ciInsertable
        <*> optionalFieldWithDefault "updatable" False "Whether or not the column can be updated" .= _ciUpdatable
        <*> optionalFieldOrNull "value_generated" "Whether or not and how the value of the column can be generated by the database" .= _ciValueGenerated

data ColumnValueGenerationStrategy
  = AutoIncrement
  | UniqueIdentifier
  | DefaultValue
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (NFData, Hashable)
  deriving (FromJSON, ToJSON, ToSchema) via Autodocodec ColumnValueGenerationStrategy

-- | We're encoding the different strategies as tagged objects rather than just strings because
-- it is anticipated that additional information may need to be added to each strategy in future.
-- For example, the actual default value (a literal), or what type of unique identifier is being
-- used (eg. a UUID). By using a tagged object, we ensure the addition of such information is not
-- a breaking change to the shape of the JSON.
instance HasCodec ColumnValueGenerationStrategy where
  codec =
    named "ColumnValueGenerationStrategy" $ object "ColumnValueGenerationStrategy" $ discriminatedUnionCodec "type" enc dec
    where
      autoIncrementCodec = pure ()
      uniqueIdentifierCodec = pure ()
      defaultCodec = pure ()
      enc = \case
        AutoIncrement -> ("auto_increment", mapToEncoder () autoIncrementCodec)
        UniqueIdentifier -> ("unique_identifier", mapToEncoder () uniqueIdentifierCodec)
        DefaultValue -> ("default_value", mapToEncoder () defaultCodec)
      dec =
        HashMap.fromList
          [ ("auto_increment", ("AutoIncrementGenerationStrategy", mapToDecoder (const AutoIncrement) autoIncrementCodec)),
            ("unique_identifier", ("UniqueIdentifierGenerationStrategy", mapToDecoder (const UniqueIdentifier) uniqueIdentifierCodec)),
            ("default_value", ("DefaultValueGenerationStrategy", mapToDecoder (const DefaultValue) uniqueIdentifierCodec))
          ]

$(makeLenses ''ColumnInfo)
