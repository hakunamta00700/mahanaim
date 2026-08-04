## Optional PostgreSQL live contract test.
##
## The default unit suite remains deterministic and credential-free. When the
## documented MAHANAIM_POSTGRES_* variables are present, this test exercises
## the real libpq connection, transaction boundary, parameter binding, and
## isolation contract through the same fixture used by application tests.

import std/[options]
import mahanaim/[database, postgres_testing, testing]

proc runLiveContract() =
  let configuration = postgresTestConfigurationFromEnv()
  if configuration.isNone:
    echo "PostgreSQL live test skipped: credentials are not configured"
    quit(0)

  let fixture = newPostgresTestFixture(configuration.get())
  defer: fixture.close()
  var observedValue = ""
  fixture.withTestDatabase(proc(adapter: DatabaseAdapter) =
    ## The fixture has already begun a transaction; isolation must be applied
    ## before the first statement so the adapter cannot silently defer it.
    adapter.setIsolationLevel(isolationReadCommitted)
    let rows = adapter.execute(CompiledQuery(
      sql: "SELECT $1::text", parameters: @[textValue("mahanaim-live")]))
    if rows.len != 1 or rows[0].len != 1 or rows[0][0].kind != sqlText:
      raise newException(ValueError, "Unexpected PostgreSQL live query result")
    observedValue = rows[0][0].text)
  if observedValue != "mahanaim-live":
    raise newException(ValueError, "PostgreSQL live contract result mismatch")
  echo "PostgreSQL live contract passed"

when isMainModule:
  runLiveContract()
