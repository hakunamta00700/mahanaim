## Optional PostgreSQL live contract test.
##
## The default unit suite remains deterministic and credential-free. When the
## documented MAHANAIM_POSTGRES_* variables are present, this test exercises
## the real libpq connection, transaction boundary, parameter binding, and
## isolation contract through the same fixture used by application tests.

import std/[asyncdispatch, httpcore, options]
import mahanaim/[application, core, database, database_repository, models,
                postgres_testing, resources, testing]

proc runLiveContract() =
  let configuration = postgresTestConfigurationFromEnv()
  if configuration.isNone:
    echo "PostgreSQL live test skipped: credentials are not configured"
    quit(0)

  let fixture = newPostgresTestFixture(configuration.get())
  defer: fixture.close()
  var observedValue = ""
  var routeObserved = false
  fixture.withTestDatabase(proc(adapter: DatabaseAdapter) =
    ## The fixture has already begun a transaction; isolation must be applied
    ## before the first statement so the adapter cannot silently defer it.
    adapter.setIsolationLevel(isolationSerializable)
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"mahanaim_live_items\" (\"id\" INTEGER, \"title\" TEXT)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"mahanaim_live_items\" VALUES ($1, $2)",
      parameters: @[integerValue(1), textValue("live")]))
    let rows = adapter.execute(CompiledQuery(
      sql: "SELECT $1::text", parameters: @[textValue("mahanaim-live")]))
    if rows.len != 1 or rows[0].len != 1 or rows[0][0].kind != sqlText:
      raise newException(ValueError, "Unexpected PostgreSQL live query result")
    observedValue = rows[0][0].text

    var metadata = newModelMetadata("LiveItem", "mahanaim_live_items")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("title", modelString))
    let repository = newDatabaseRepository(metadata, adapter)
    let app = newApplication()
    registerCrudRoutes(app,
      newCrudResource(metadata, newDatabaseRepositoryResourceStore(repository)),
      "/live-items", "live-items")
    let response = waitFor app.dispatch(newRequest("GET", "/live-items"))
    routeObserved = response.status == Http200 and response.body.contains("live"))
  if observedValue != "mahanaim-live":
    raise newException(ValueError, "PostgreSQL live contract result mismatch")
  if not routeObserved:
    raise newException(ValueError, "PostgreSQL live repository route mismatch")

  var rollbackObserved = false
  fixture.withTestDatabase(proc(adapter: DatabaseAdapter) =
    try:
      discard adapter.execute(CompiledQuery(sql:
        "SELECT id FROM \"mahanaim_live_items\"", parameters: @[]))
    except CatchableError:
      rollbackObserved = true)
  if not rollbackObserved:
    raise newException(ValueError, "PostgreSQL fixture did not rollback live DDL")
  echo "PostgreSQL live contract passed"

when isMainModule:
  runLiveContract()
