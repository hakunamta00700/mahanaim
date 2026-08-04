## Compile-only contract test for the optional PostgreSQL adapter.
##
## libpq is a runtime native dependency and is intentionally not required by
## the default SQLite/core test process. This fixture still compiles the full
## adapter API so source drift is caught in CI without opening a server.

import mahanaim/postgres_adapter
import mahanaim/postgres_testing

static:
  doAssert compiles(PostgresDatabaseAdapter)
  doAssert compiles(newPostgresDatabaseAdapter("host", "user", "password", "db"))
  doAssert compiles(PostgresTestConfiguration)
  doAssert compiles(postgresTestConfigurationFromEnv())
  doAssert compiles(newPostgresTestFixture(
    newPostgresTestConfiguration("127.0.0.1", "user", "password", "db")))
  doAssert compiles(newPostgresTestFixtureFromEnv())
