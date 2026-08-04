## SQLite driver adapter backed by the official Nim db_connector package.
##
## Query compilation remains owned by `database.nim`; this module only binds
## the compiled values and translates driver lifecycle calls. That boundary
## keeps PostgreSQL and future drivers interchangeable with the same contract.

import std/[options, strutils]
import pkg/db_connector/[db_sqlite, sqlite3]
import ./database

type
  SqliteDatabaseAdapter* = ref object of DatabaseAdapter
    ## One adapter owns one connection. Pooling is intentionally a separate
    ## layer so connection lifetime and transaction ownership stay explicit.
    connection*: DbConn
    path*: string

proc newSqliteDatabaseAdapter*(path = ":memory:"): SqliteDatabaseAdapter =
  ## Open a file or an isolated in-memory database using SQLite's native API.
  if path.strip().len == 0:
    raise newException(ValueError, "SQLite path cannot be empty")
  result = SqliteDatabaseAdapter(dialect: dialectSqlite,
    capabilities: capabilitiesForDialect(dialectSqlite),
    connection: db_sqlite.open(path, "", "", ""), path: path)

proc close*(adapter: SqliteDatabaseAdapter) =
  ## Closing is idempotent so application shutdown hooks can safely call it.
  if not adapter.isNil and not adapter.connection.isNil:
    db_sqlite.close(adapter.connection)
    adapter.connection = nil

proc bindValue(statement: SqlPrepared, index: int, value: SqlValue) =
  ## Bind by type; no value is interpolated into SQL text.
  case value.kind
  of sqlNull: statement.bindNull(index)
  of sqlText: statement.bindParam(index, value.text)
  of sqlInteger: statement.bindParam(index, value.integer)
  of sqlFloat: statement.bindParam(index, value.floating.float64)
  of sqlBoolean: statement.bindParam(index, if value.boolean: 1'i64 else: 0'i64)
  of sqlList: raise newException(ValueError, "SQLite bind received an unexpanded list")

proc sqliteValueKindForDeclaration*(declaredType: string): SqlValueKind =
  ## SQLite has no single stable OID. Its declared type affinity is therefore
  ## the portable metadata source for table projections and keeps the neutral
  ## result contract independent from SQLite C handles.
  let normalized = declaredType.toUpperAscii()
  if normalized.contains("BOOL"):
    return sqlBoolean
  if normalized.contains("INT"):
    return sqlInteger
  if normalized.contains("REAL") or normalized.contains("FLOA") or
      normalized.contains("DOUB") or normalized.contains("NUM") or
      normalized.contains("DEC"):
    return sqlFloat
  sqlText

proc sqliteValueKindForDriverType(typeCode: int32): SqlValueKind =
  ## Expressions and aliases may not have a declared SQLite type. In that case
  ## SQLite exposes the runtime storage class after the first `step` call.
  case typeCode
  of SQLITE_INTEGER: sqlInteger
  of SQLITE_FLOAT: sqlFloat
  else: sqlText

proc sqliteValueForKind(value: string, kind: SqlValueKind): SqlValue =
  ## Parse only declared scalar affinities. A failed conversion stays text so
  ## malformed or extension values are observable instead of being corrupted.
  case kind
  of sqlBoolean:
    booleanValue(value.toLowerAscii() in ["1", "true", "t", "yes"])
  of sqlInteger:
    try: integerValue(parseInt(value).int64)
    except ValueError: textValue(value)
  of sqlFloat:
    try: floatValue(parseFloat(value))
    except ValueError: textValue(value)
  else: textValue(value)

method executeResult*(adapter: SqliteDatabaseAdapter,
                      query: CompiledQuery): DatabaseResult {.gcsafe.} =
  ## Execute SELECT or DML and retain SQLite's result column metadata beside
  ## rows. The small direct stepping loop is intentional: db_connector's
  ## metadata iterator cannot accept an already-bound `SqlPrepared`, while the
  ## framework must preserve typed parameter binding and NULL semantics.
  if adapter.isNil or adapter.connection.isNil:
    raise newException(ValueError, "SQLite adapter is closed")
  let statement = adapter.connection.prepare(query.sql)
  try:
    for index, value in query.parameters:
      bindValue(statement, index + 1, value)
  except CatchableError:
    db_sqlite.finalize(statement)
    raise
  let rawStatement = statement.PStmt
  defer: discard sqlite3.finalize(rawStatement)
  let columnCount = column_count(rawStatement).int
  var declaredTypes = newSeq[string](columnCount)
  for index in 0 ..< columnCount:
    let declared = column_decltype(rawStatement, index.int32)
    declaredTypes[index] = if declared.isNil: "" else: $declared
    result.columns.add(DatabaseColumnMetadata(
      name: $column_name(rawStatement, index.int32),
      kind: sqliteValueKindForDeclaration(declaredTypes[index]),
      backendTypeId: 0))
  var firstRow = true
  while true:
    let status = step(rawStatement)
    if status == SQLITE_DONE:
      break
    if status != SQLITE_ROW:
      raise newException(CatchableError, "SQLite query failed while stepping")
    if firstRow:
      ## Resolve expression projections such as `COUNT(*)` from the first
      ## runtime value without overriding declared table-column affinity.
      for index in 0 ..< columnCount:
        if declaredTypes[index].strip().len == 0:
          result.columns[index].kind = sqliteValueKindForDriverType(
            column_type(rawStatement, index.int32))
      firstRow = false
    var converted: seq[SqlValue] = @[]
    for index in 0 ..< columnCount:
      if column_type(rawStatement, index.int32) == SQLITE_NULL:
        converted.add(nullValue())
      else:
        converted.add(sqliteValueForKind($column_text(rawStatement,
          index.int32), result.columns[index].kind))
    result.rows.add(converted)

method execute*(adapter: SqliteDatabaseAdapter,
                query: CompiledQuery): seq[seq[SqlValue]] {.gcsafe.} =
  ## Preserve the original row-only method while sharing the typed execution
  ## path with callers that request metadata explicitly.
  adapter.executeResult(query).rows

proc execControl(adapter: SqliteDatabaseAdapter, statement: string) {.gcsafe.} =
  ## Keep lifecycle SQL centralized and free from caller-provided fragments.
  if adapter.isNil or adapter.connection.isNil:
    raise newException(ValueError, "SQLite adapter is closed")
  adapter.connection.exec(SqlQuery(statement))

method begin*(adapter: SqliteDatabaseAdapter) {.gcsafe.} = adapter.execControl("BEGIN")
method commit*(adapter: SqliteDatabaseAdapter) {.gcsafe.} = adapter.execControl("COMMIT")
method rollback*(adapter: SqliteDatabaseAdapter) {.gcsafe.} = adapter.execControl("ROLLBACK")

proc safeSavepointName(name: string): string =
  if name.len == 0:
    raise newException(ValueError, "Savepoint name cannot be empty")
  for character in name:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      raise newException(ValueError, "Unsafe savepoint name: " & name)
  "\"" & name & "\""

method savepoint*(adapter: SqliteDatabaseAdapter, name: string) {.gcsafe.} =
  adapter.execControl("SAVEPOINT " & safeSavepointName(name))

method rollbackToSavepoint*(adapter: SqliteDatabaseAdapter, name: string) {.gcsafe.} =
  adapter.execControl("ROLLBACK TO SAVEPOINT " & safeSavepointName(name))

method releaseSavepoint*(adapter: SqliteDatabaseAdapter, name: string) {.gcsafe.} =
  adapter.execControl("RELEASE SAVEPOINT " & safeSavepointName(name))

proc applyMigration*(adapter: SqliteDatabaseAdapter, migration: Migration) =
  ## Apply all up operations atomically; a failed operation rolls back prior DDL.
  adapter.withTransaction(proc() =
    for operation in migration.up:
      adapter.execControl(migrationSql(operation, dialectSqlite)))

proc rollbackMigration*(adapter: SqliteDatabaseAdapter, migration: Migration) =
  ## Down operations use the same atomic boundary as forward migrations.
  adapter.withTransaction(proc() =
    for operation in migration.down:
      adapter.execControl(migrationSql(operation, dialectSqlite)))

const migrationTable = "__mahanaim_migrations"

proc ensureMigrationTable(adapter: SqliteDatabaseAdapter) =
  ## The history table is framework-owned and uses a stable reserved name.
  adapter.execControl("CREATE TABLE IF NOT EXISTS \"" & migrationTable &
    "\" (\"sequence\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" TEXT NOT NULL UNIQUE)")

proc appliedMigrations*(adapter: SqliteDatabaseAdapter): seq[string] =
  ## Return applied names in execution order for diagnostics and CLI output.
  adapter.ensureMigrationTable()
  let rows = adapter.execute(CompiledQuery(sql:
    "SELECT \"name\" FROM \"" & migrationTable & "\" ORDER BY \"sequence\"",
    parameters: @[]))
  for row in rows:
    if row.len > 0:
      result.add(row[0].text)

proc validateMigrations(migrations: openArray[Migration]) =
  var names: seq[string] = @[]
  for migration in migrations:
    if migration.name.strip().len == 0:
      raise newException(ValueError, "Migration name cannot be empty")
    if migration.name in names:
      raise newException(ValueError, "Duplicate migration: " & migration.name)
    names.add(migration.name)

proc migrate*(adapter: SqliteDatabaseAdapter,
              migrations: openArray[Migration]): seq[string] =
  ## Apply pending migrations one at a time and record each atomically.
  validateMigrations(migrations)
  adapter.ensureMigrationTable()
  let applied = adapter.appliedMigrations()
  for migration in migrations:
    ## Copy the openArray element before capturing it in the transaction
    ## callback; Nim's lent iterator safety rules forbid capturing the view.
    let currentMigration = migration
    if currentMigration.name in applied:
      continue
    adapter.withTransaction(proc() =
      for operation in currentMigration.up:
        adapter.execControl(migrationSql(operation, dialectSqlite))
      let statement = adapter.connection.prepare(
        "INSERT INTO \"" & migrationTable & "\" (\"name\") VALUES (?)")
      try:
        statement.bindParam(1, currentMigration.name)
        for _ in adapter.connection.fastRows(statement):
          discard
      finally:
        db_sqlite.finalize(statement))
    result.add(currentMigration.name)

proc rollbackLatest*(adapter: SqliteDatabaseAdapter,
                     migrations: openArray[Migration]): Option[string] =
  ## Roll back exactly the latest recorded migration, preserving stack order.
  validateMigrations(migrations)
  adapter.ensureMigrationTable()
  let rows = adapter.execute(CompiledQuery(sql:
    "SELECT \"name\" FROM \"" & migrationTable &
    "\" ORDER BY \"sequence\" DESC LIMIT 1", parameters: @[]))
  if rows.len == 0 or rows[0].len == 0:
    return none(string)
  let name = rows[0][0].text
  var selected: Option[Migration] = none(Migration)
  for migration in migrations:
    if migration.name == name:
      selected = some(migration)
      break
  if selected.isNone:
    raise newException(ValueError, "Migration definition is missing: " & name)
  ## Keep an owned copy for the callback instead of capturing an Option view.
  let currentMigration = selected.get()
  adapter.withTransaction(proc() =
    for operation in currentMigration.down:
      adapter.execControl(migrationSql(operation, dialectSqlite))
    let statement = adapter.connection.prepare(
      "DELETE FROM \"" & migrationTable & "\" WHERE \"name\" = ?")
    try:
      statement.bindParam(1, name)
      for _ in adapter.connection.fastRows(statement):
        discard
    finally:
      db_sqlite.finalize(statement))
  some(name)
