## Compile-only contract test for the optional PostgreSQL adapter.
##
## libpq is a runtime native dependency and is intentionally not required by
## the default SQLite/core test process. This fixture still compiles the full
## adapter API so source drift is caught in CI without opening a server.

import mahanaim/postgres_adapter
import mahanaim/postgres_testing
import mahanaim/database
import mahanaim/migration_commands

static:
  doAssert compiles(PostgresDatabaseAdapter)
  doAssert compiles(newPostgresDatabaseAdapter("host", "user", "password", "db"))
  doAssert compiles(PostgresTestConfiguration)
  doAssert compiles(postgresTestConfigurationFromEnv())
  doAssert compiles(newPostgresTestFixture(
    newPostgresTestConfiguration("127.0.0.1", "user", "password", "db")))
  doAssert compiles(newPostgresTestFixtureFromEnv())
  let migration = Migration(name: "compile_migration", up: @[], down: @[])
  doAssert compiles(newPostgresDatabaseAdapter("host", "user", "password", "db").migrate([migration]))
  doAssert compiles(newPostgresDatabaseAdapter("host", "user", "password", "db").rollbackLatest([migration]))
  doAssert compiles(executeMigrationCommand(
    newPostgresDatabaseAdapter("host", "user", "password", "db"),
    [migration], parseMigrationCommand(["status"])))
  doAssert postgresValueKindForOid(16) == sqlBoolean
  doAssert postgresValueKindForOid(23) == sqlInteger
  doAssert postgresValueKindForOid(701) == sqlFloat
  doAssert postgresValueKindForOid(3802) == sqlText
  let integerColumn = postgresColumnMetadataForOid("user_id", 23)
  doAssert integerColumn.name == "user_id"
  doAssert integerColumn.kind == sqlInteger
  doAssert integerColumn.backendTypeId == 23
  doAssert compiles(DatabaseResult(columns: @[], rows: @[]))
