## Optional PostgreSQL live contract test.
##
## The default unit suite remains deterministic and credential-free. When the
## documented MAHANAIM_POSTGRES_* variables are present, this test exercises
## the real libpq connection, transaction boundary, parameter binding, and
## isolation contract through the same fixture used by application tests.

import std/[asyncdispatch, atomics, httpcore, httpclient, json, options,
            strutils, tables]
import mahanaim/[application, core, database, database_repository, models,
                database_pool, database_session, migration_commands,
                postgres_adapter, postgres_testing,
                http_adapter, resources, serialization, testing]

proc encodeLiveMoney(field: ModelField, value: JsonNode): JsonNode {.gcsafe.} =
  ## The live contract uses an application-owned codec rather than teaching
  ## PostgreSQL about an arbitrary Nim domain type. The database stores the
  ## JSON wire value; this codec proves the same explicit `wireType` metadata
  ## is still applied after a typed PostgreSQL result has crossed the adapter.
  if field.wireType != "money" or value.kind != JObject or
      not value.hasKey("currency") or not value.hasKey("minor"):
    raise newException(ValueError, "live money codec received an invalid value")
  if value["currency"].kind != JString or value["minor"].kind != JInt:
    raise newException(ValueError, "live money codec received invalid fields")
  %*{"currency": value["currency"].getStr().toUpperAscii(),
      "minor": value["minor"].getInt()}

proc runLiveMigrationContract(configuration: PostgresTestConfiguration) =
  ## Migration history is tested on a dedicated connection because the normal
  ## fixture wraps a callback in an outer rollback transaction. The migration
  ## runner owns its own begin/commit boundary and must be tested at that seam.
  let adapter = newPostgresDatabaseAdapter(
    configuration.host & ":" & $configuration.port,
    configuration.user, configuration.password, configuration.database)
  defer: adapter.close()
  let tableName = "mahanaim_live_migration_items"
  let migration = Migration(name: "mahanaim_live_migration_001", up: @[
    MigrationOperation(kind: migrationCreateTable, table: tableName,
      field: newModelField("message", modelString))], down: @[
    MigrationOperation(kind: migrationDropTable, table: tableName)])
  ## Exercise the same command overload used by embedding and standalone CLI
  ## callers. Calling only `adapter.migrate` would leave that public boundary
  ## unproven even though the underlying SQL happened to succeed.
  let statusBefore = executeMigrationCommand(adapter, [migration],
    parseMigrationCommand(["status"]))
  if statusBefore.applied.len != 0:
    raise newException(ValueError, "PostgreSQL migration status was not empty")
  let applied = executeMigrationCommand(adapter, [migration],
    parseMigrationCommand(["up"]))
  if applied.applied != @[migration.name] or
      adapter.appliedMigrations() != @[migration.name]:
    raise newException(ValueError, "PostgreSQL migration history mismatch")
  let historyRows = adapter.execute(CompiledQuery(sql:
    "SELECT \"name\" FROM \"__mahanaim_migrations\" ORDER BY \"sequence\"",
    parameters: @[]))
  if historyRows.len != 1 or historyRows[0][0].text != migration.name:
    raise newException(ValueError, "PostgreSQL migration schema history mismatch")
  let idempotent = executeMigrationCommand(adapter, [migration],
    parseMigrationCommand(["migrate"]))
  if idempotent.applied.len != 0:
    raise newException(ValueError, "PostgreSQL migration was not idempotent")
  let statusAfterUp = executeMigrationCommand(adapter, [migration],
    parseMigrationCommand(["status"]))
  if statusAfterUp.applied != @[migration.name]:
    raise newException(ValueError, "PostgreSQL migration status mismatch")
  let rolledBack = executeMigrationCommand(adapter, [migration],
    parseMigrationCommand(["rollback"]))
  if rolledBack.rolledBack.isNone or rolledBack.rolledBack.get() != migration.name or
      adapter.appliedMigrations().len != 0:
    raise newException(ValueError, "PostgreSQL migration rollback mismatch")
  let statusAfterRollback = executeMigrationCommand(adapter, [migration],
    parseMigrationCommand(["status"]))
  if statusAfterRollback.applied.len != 0:
    raise newException(ValueError, "PostgreSQL rollback status mismatch")
  ## The history table is framework-owned test state; remove it after proving
  ## status/up/rollback so repeated live runs do not accumulate metadata.
  discard adapter.execute(CompiledQuery(sql:
    "DROP TABLE IF EXISTS \"__mahanaim_migrations\"", parameters: @[]))

proc runLivePoolSessionContract(configuration: PostgresTestConfiguration) =
  ## Exercise the real libpq connection through the framework-owned pool and
  ## request session, not only through a directly borrowed adapter. The table
  ## is committed outside the session assertions so every pooled connection
  ## observes the same schema.
  let setup = newPostgresDatabaseAdapter(
    configuration.host & ":" & $configuration.port,
    configuration.user, configuration.password, configuration.database)
  let tableName = "mahanaim_live_pool_items"
  discard setup.execute(CompiledQuery(sql:
    "DROP TABLE IF EXISTS \"" & tableName & "\"", parameters: @[]))
  discard setup.execute(CompiledQuery(sql:
    "CREATE TABLE \"" & tableName & "\" (" &
    "\"id\" INTEGER PRIMARY KEY, \"value\" TEXT)", parameters: @[]))
  setup.close()

  var closedConnections: Atomic[int]
  closedConnections.store(0)
  let pool = newDatabaseConnectionPool(
    proc(): DatabaseAdapter {.gcsafe.} =
      newPostgresDatabaseAdapter(configuration.host & ":" &
        $configuration.port, configuration.user, configuration.password,
        configuration.database),
    maxConnections = 1,
    closer = proc(adapter: DatabaseAdapter) {.gcsafe.} =
      discard closedConnections.fetchAdd(1)
      PostgresDatabaseAdapter(adapter).close())
  defer:
    pool.close()

  let committed = newDatabaseSession(pool)
  committed.setIsolationLevel(isolationSerializable)
  discard committed.adapter.execute(CompiledQuery(sql:
    "INSERT INTO \"" & tableName & "\" VALUES ($1, $2)",
    parameters: @[integerValue(1), textValue("committed")]))
  committed.commit()
  committed.close()
  if pool.idleCount() != 1 or pool.activeCount() != 0:
    raise newException(ValueError, "PostgreSQL pool did not return committed session")

  let observed = newDatabaseSession(pool)
  let committedRows = observed.adapter.execute(CompiledQuery(sql:
    "SELECT \"value\" FROM \"" & tableName & "\" WHERE \"id\" = $1",
    parameters: @[integerValue(1)]))
  if committedRows.len != 1 or committedRows[0][0].text != "committed":
    raise newException(ValueError, "PostgreSQL session did not observe commit")
  observed.rollback()
  observed.close()

  let rolledBack = newDatabaseSession(pool)
  discard rolledBack.adapter.execute(CompiledQuery(sql:
    "INSERT INTO \"" & tableName & "\" VALUES ($1, $2)",
    parameters: @[integerValue(2), textValue("rolled-back")]))
  rolledBack.close()

  let verifyRollback = newDatabaseSession(pool)
  let rollbackRows = verifyRollback.adapter.execute(CompiledQuery(sql:
    "SELECT \"id\" FROM \"" & tableName & "\" WHERE \"id\" = $1",
    parameters: @[integerValue(2)]))
  if rollbackRows.len != 0:
    raise newException(ValueError, "PostgreSQL session close did not rollback")
  verifyRollback.rollback()
  verifyRollback.close()

  let active = pool.acquire()
  pool.close()
  pool.release(active)
  if closedConnections.load() < 1:
    raise newException(ValueError, "PostgreSQL pool did not close active connection")

  let cleanup = newPostgresDatabaseAdapter(
    configuration.host & ":" & $configuration.port,
    configuration.user, configuration.password, configuration.database)
  discard cleanup.execute(CompiledQuery(sql:
    "DROP TABLE IF EXISTS \"" & tableName & "\"", parameters: @[]))
  cleanup.close()

proc runLiveServerContract(configuration: PostgresTestConfiguration) =
  ## Exercise the real network adapter and application dispatch path with a
  ## PostgreSQL-backed request. This proves pool borrowing happens around a
  ## wire request rather than only around an in-process handler call.
  let tableName = "mahanaim_live_server_items"
  let setup = newPostgresDatabaseAdapter(
    configuration.host & ":" & $configuration.port,
    configuration.user, configuration.password, configuration.database)
  discard setup.execute(CompiledQuery(sql:
    "DROP TABLE IF EXISTS \"" & tableName & "\"", parameters: @[]))
  discard setup.execute(CompiledQuery(sql:
    "CREATE TABLE \"" & tableName & "\" (" &
    "\"id\" INTEGER PRIMARY KEY, \"message\" TEXT)", parameters: @[]))
  discard setup.execute(CompiledQuery(sql:
    "INSERT INTO \"" & tableName & "\" VALUES ($1, $2)",
    parameters: @[integerValue(1), textValue("postgres-live-server")]))
  setup.close()

  let pool = newDatabaseConnectionPool(
    proc(): DatabaseAdapter {.gcsafe.} =
      newPostgresDatabaseAdapter(configuration.host & ":" &
        $configuration.port, configuration.user, configuration.password,
        configuration.database),
    maxConnections = 1,
    closer = proc(adapter: DatabaseAdapter) {.gcsafe.} =
      PostgresDatabaseAdapter(adapter).close())
  let app = newApplication()
  app.configureDatabasePool(pool)
  proc liveRoute(request: Request): Future[core.Response] {.async, gcsafe.} =
    ## The adapter injects the borrowed connection before this route runs.
    let rows = request.database.execute(CompiledQuery(sql:
      "SELECT \"message\" FROM \"" & tableName & "\" WHERE \"id\" = $1",
      parameters: @[integerValue(1)]))
    if rows.len != 1:
      return textResponse("missing live row", Http500)
    return textResponse(rows[0][0].text)
  app.get("/postgres-live", "postgres-live", liveRoute)

  let network = newNetworkServer(app, "127.0.0.1", 0)
  asyncCheck network.serve()
  var attempts = 0
  while attempts < 100:
    try:
      if network.boundPort().uint16 > 0:
        break
    except OSError:
      discard
    waitFor sleepAsync(10)
    inc attempts
  if network.boundPort().uint16 == 0:
    network.close()
    raise newException(IOError, "PostgreSQL live server did not bind")

  let client = newAsyncHttpClient()
  let response = waitFor client.getContent(
    "http://127.0.0.1:" & $network.boundPort().uint16 & "/postgres-live")
  client.close()
  network.close()
  if response != "postgres-live-server":
    raise newException(ValueError, "PostgreSQL live server response mismatch")

  let cleanup = newPostgresDatabaseAdapter(
    configuration.host & ":" & $configuration.port,
    configuration.user, configuration.password, configuration.database)
  discard cleanup.execute(CompiledQuery(sql:
    "DROP TABLE IF EXISTS \"" & tableName & "\"", parameters: @[]))
  cleanup.close()

proc runLiveContract() =
  let configuration = postgresTestConfigurationFromEnv()
  if configuration.isNone:
    echo "PostgreSQL live test skipped: credentials are not configured"
    quit(0)

  runLiveMigrationContract(configuration.get())
  runLivePoolSessionContract(configuration.get())
  runLiveServerContract(configuration.get())

  let fixture = newPostgresTestFixture(configuration.get())
  defer: fixture.close()
  var observedValue = ""
  var routeObserved = false
  fixture.withTestDatabase(proc(adapter: DatabaseAdapter) =
    ## The fixture has already begun a transaction; isolation must be applied
    ## before the first statement so the adapter cannot silently defer it.
    adapter.setIsolationLevel(isolationSerializable)
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"mahanaim_live_items\" (\"id\" INTEGER PRIMARY KEY, " &
      "\"title\" TEXT, \"status\" TEXT, \"active\" BOOLEAN, " &
      "\"amount\" INTEGER)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"mahanaim_live_comments\" (\"id\" INTEGER PRIMARY KEY, " &
      "\"item_id\" INTEGER, \"body\" TEXT)", parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"mahanaim_live_custom\" (\"id\" INTEGER PRIMARY KEY, " &
      "\"price\" JSONB)", parameters: @[]))
    for values in @[
        (1, "live", "open", true, 10),
        (2, "second", "open", true, 5),
        (3, "closed", "closed", false, 7)]:
      discard adapter.execute(CompiledQuery(sql:
        "INSERT INTO \"mahanaim_live_items\" VALUES ($1, $2, $3, $4, $5)",
        parameters: @[integerValue(values[0]), textValue(values[1]),
          textValue(values[2]), booleanValue(values[3]),
          integerValue(values[4])]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"mahanaim_live_comments\" VALUES ($1, $2, $3)",
      parameters: @[integerValue(1), integerValue(1), textValue("first")] ))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"mahanaim_live_comments\" VALUES ($1, $2, $3)",
      parameters: @[integerValue(2), integerValue(1), textValue("second")] ))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"mahanaim_live_custom\" VALUES ($1, $2::jsonb)",
      parameters: @[integerValue(1),
        textValue("{\"currency\":\"usd\",\"minor\":1250}")] ))
    let typedResult = adapter.executeResult(CompiledQuery(sql:
      "SELECT \"id\", \"active\", \"amount\" FROM \"mahanaim_live_items\" " &
      "ORDER BY \"id\"", parameters: @[]))
    if typedResult.columns.len != 3 or typedResult.columns[0].name != "id" or
        typedResult.columns[0].kind != sqlInteger or
        typedResult.columns[1].kind != sqlBoolean or
        typedResult.columns[2].kind != sqlInteger or
        typedResult.rows.len != 3 or typedResult.rows[0][1].kind != sqlBoolean:
      raise newException(ValueError, "Unexpected PostgreSQL column metadata")
    let customResult = adapter.executeResult(CompiledQuery(sql:
      "SELECT \"price\" FROM \"mahanaim_live_custom\" WHERE \"id\" = $1",
      parameters: @[integerValue(1)]))
    if customResult.columns.len != 1 or customResult.columns[0].kind != sqlText or
        customResult.columns[0].backendTypeId != 3802 or
        customResult.rows.len != 1 or customResult.rows[0][0].kind != sqlText:
      raise newException(ValueError,
        "Unexpected PostgreSQL custom field result metadata")
    let customMetadata = ModelMetadata(name: "LiveCustom", tableName:
      "mahanaim_live_custom", fields: @[newModelField("id", modelInteger,
        primaryKey = true), newModelCustomField("price", "money")])
    let codecRegistry = newSerializationAdapterRegistry()
    codecRegistry.registerCodec("money", encodeLiveMoney)
    let customValue = parseJson(customResult.rows[0][0].text)
    var customValues = initTable[string, JsonNode]()
    customValues["id"] = newJInt(1)
    customValues["price"] = customValue
    let encodedCustom = serializeModel(customMetadata, customValues,
      adapter = codecRegistry)
    if not encodedCustom.valid or encodedCustom.document["price"]["currency"].getStr() !=
        "USD" or encodedCustom.document["price"]["minor"].getInt() != 1250:
      raise newException(ValueError,
        "PostgreSQL custom field codec mapping mismatch")
    let rows = adapter.execute(CompiledQuery(
      sql: "SELECT $1::text", parameters: @[textValue("mahanaim-live")]))
    if rows.len != 1 or rows[0].len != 1 or rows[0][0].kind != sqlText:
      raise newException(ValueError, "Unexpected PostgreSQL live query result")
    observedValue = rows[0][0].text

    var metadata = newModelMetadata("LiveItem", "mahanaim_live_items")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("title", modelString))
    metadata.addField(newModelField("status", modelString))
    metadata.addField(newModelField("active", modelBoolean))
    metadata.addField(newModelField("amount", modelInteger))
    let repository = newDatabaseRepository(metadata, adapter)
    let filtered = repository.list(SelectQuery(
      filters: @[QueryFilter(field: "active", operator: filterEqual,
        value: booleanValue(true))], orderBy: @[QueryOrder(field: "id")]))
    if filtered.len != 2 or filtered[0]["title"].getStr() != "live":
      raise newException(ValueError, "PostgreSQL live filtering mismatch")
    let aggregateRows = repository.aggregate(newQuerySet("mahanaim_live_items")
      .selectFields(@["status"])
      .whereFilter(QueryFilter(field: "active", operator: filterEqual,
        value: booleanValue(true)))
      .addAggregate(aggregateCount, "*", "total")
      .addAggregate(aggregateSum, "amount", "gross")
      .groupByFields(@["status"]).orderByField("status"))
    if aggregateRows.len != 1 or aggregateRows[0]["status"].getStr() != "open" or
        aggregateRows[0]["total"].getInt() != 2 or
        aggregateRows[0]["gross"].getInt() != 15:
      raise newException(ValueError, "PostgreSQL live aggregate mismatch")
    var comments = newModelMetadata("LiveComment", "mahanaim_live_comments")
    comments.addField(newModelField("id", modelInteger, primaryKey = true))
    comments.addField(newModelField("item_id", modelInteger))
    comments.addField(newModelField("body", modelString))
    let relation = ModelRelation(name: "comments", kind: relationOneToMany,
      targetModel: "LiveComment", localField: "id", foreignField: "item_id")
    let related = repository.listRelation(relation, comments)
    if related.len != 2 or related[0]["title"].getStr() != "live":
      raise newException(ValueError, "PostgreSQL live relation mismatch")
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
