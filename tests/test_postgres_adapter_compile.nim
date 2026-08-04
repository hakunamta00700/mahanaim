## Compile-only contract test for the optional PostgreSQL adapter.
##
## libpq is a runtime native dependency and is intentionally not required by
## the default SQLite/core test process. This fixture still compiles the full
## adapter API so source drift is caught in CI without opening a server.

import mahanaim/postgres_adapter

static:
  doAssert compiles(PostgresDatabaseAdapter)
  doAssert compiles(newPostgresDatabaseAdapter("host", "user", "password", "db"))
