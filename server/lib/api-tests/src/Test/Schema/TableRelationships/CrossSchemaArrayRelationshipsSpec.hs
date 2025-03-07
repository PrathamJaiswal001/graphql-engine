{-# LANGUAGE QuasiQuotes #-}

-- | we can fetch across schemas! Yes, we can!
module Test.Schema.TableRelationships.CrossSchemaArrayRelationshipsSpec (spec) where

import Data.Aeson (Value)
import Data.List.NonEmpty qualified as NE
import Harness.Backend.Postgres qualified as Postgres
import Harness.GraphqlEngine (postGraphql)
import Harness.Quoter.Graphql (graphql)
import Harness.Quoter.Yaml (interpolateYaml)
import Harness.Test.Fixture qualified as Fixture
import Harness.Test.Schema (Table (..), table)
import Harness.Test.Schema qualified as Schema
import Harness.TestEnvironment (GlobalTestEnvironment, TestEnvironment)
import Harness.Yaml (shouldReturnYaml)
import Hasura.Prelude
import Test.Hspec (SpecWith, describe, it)

spec :: SpecWith GlobalTestEnvironment
spec = do
  Fixture.run
    ( NE.fromList
        [ (Fixture.fixture $ Fixture.Backend Postgres.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [Postgres.setupTablesAction schema testEnv]
            }
        ]
    )
    tests

--------------------------------------------------------------------------------
-- Schema

schema :: [Schema.Table]
schema =
  [ (table "author")
      { tableColumns =
          [ Schema.column "id" Schema.TInt,
            Schema.column "name" Schema.TStr
          ],
        tablePrimaryKey = ["id"],
        tableData =
          [ [Schema.VInt 1, Schema.VStr "Author 1"],
            [Schema.VInt 2, Schema.VStr "Author 2"]
          ],
        tableQualifiers = [Schema.TableQualifier "thisschema"]
      },
    (table "article")
      { tableQualifiers =
          [ Schema.TableQualifier "thatschema"
          ],
        tableColumns =
          [ Schema.column "id" Schema.TInt,
            Schema.column "title" Schema.TStr,
            Schema.column "author_id" Schema.TInt
          ],
        tablePrimaryKey = ["id"],
        tableReferences =
          [ Schema.Reference
              { Schema.referenceLocalColumn = "author_id",
                Schema.referenceTargetTable = "author",
                Schema.referenceTargetColumn = "id",
                Schema.referenceTargetQualifiers = ["thisschema"]
              }
          ],
        tableData =
          [ [ Schema.VInt 1,
              Schema.VStr "Article 1",
              Schema.VInt 1
            ],
            [ Schema.VInt 2,
              Schema.VStr "Article 2",
              Schema.VInt 1
            ],
            [ Schema.VInt 3,
              Schema.VStr "Article 3",
              Schema.VInt 2
            ]
          ]
      }
  ]

--------------------------------------------------------------------------------
-- Tests

tests :: Fixture.Options -> SpecWith TestEnvironment
tests opts = do
  let shouldBe :: IO Value -> Value -> IO ()
      shouldBe = shouldReturnYaml opts

  describe "Array relationships across schemas" do
    it "Select authors and their articles" \testEnvironment -> do
      let expected :: Value
          expected =
            [interpolateYaml|
              data:
                thisschema_author:
                - id: 1
                  articles_by_id_to_thisschema_author_id:
                  - id: 1
                  - id: 2

                - id: 2
                  articles_by_id_to_thisschema_author_id:
                  - id: 3
            |]

          -- We have to provide explicit orderings because BigQuery doesn't
          -- seem to return results in a deterministic order.
          actual :: IO Value
          actual =
            postGraphql
              testEnvironment
              [graphql|
                query {
                  thisschema_author(order_by: [{ id: asc }]) {
                    id

                    articles_by_id_to_thisschema_author_id(order_by: [{ id: asc }]) {
                      id
                    }
                  }
                }
              |]

      actual `shouldBe` expected
