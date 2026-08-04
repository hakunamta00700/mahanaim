## SQLite driver adapter backed by the official Nim db_connector package.
##
## Query compilation remains owned by `database.nim`; this module only binds
## the compiled values and translates driver lifecycle calls. That boundary
## keeps PostgreSQL and future drivers interchangeable with the same contract.

import std/[options, strutils]
import pkg/db_connector/db_sqlite
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
    connection: db_sqlite.open(path, "", "", ""), path: path)

proc close*(adapter: SqliteDatabaseAdapter) =
  ## Closing is idempotent so application shutdown hooks can safely call it.
  if not adapter.isNil and not adapter.connection.isNil:
    adapter.connection.close()
    adapter.connection = nil

proc bindValue(statement: SqlPrepared, index: int, value: SqlValue) =
  ## Bind by type; no value is interpolated into SQL text.
  case value.kind
  of sqlNull: statement.bindNull(index)
  of sqlText: statement.bindParam(index, value.text)
  of sqlInteger: statement.bindParam(index, value.integer)
  of sqlFloat: statement.bindParam(index, value.floating.float64)
  of sqlBoolean: statement.bindParam(index, if value.boolean: 1'i64 else: 0'i64)

method execute*(adapter: SqliteDatabaseAdapter,
                query: CompiledQuery): seq[seq[SqlValue]] =
  ## Execute SELECT or DML and return text-backed rows at the neutral boundary.
  if adapter.isNil or adapter.connection.isNil:
    raise newException(ValueError, "SQLite adapter is closed")
  let statement = adapter.connection.prepare(query.sql)
  try:
    for index, value in query.parameters:
      bindValue(statement, index + 1, value)
    for row in adapter.connection.fastRows(statement):
      var converted: seq[SqlValue] = @[]
      for value in row:
        converted.add(textValue(value))
      result.add(converted)
  finally:
    statement.finalize()

proc execControl(adapter: SqliteDatabaseAdapter, statement: string) =
  ## Keep lifecycle SQL centralized and free from caller-provided fragments.
  if adapter.isNil or adapter.connection.isNil:
    raise newException(ValueError, "SQLite adapter is closed")
  adapter.connection.exec(SqlQuery(statement))

method begin*(adapter: SqliteDatabaseAdapter) = adapter.execControl("BEGIN")
method commit*(adapter: SqliteDatabaseAdapter) = adapter.execControl("COMMIT")
method rollback*(adapter: SqliteDatabaseAdapter) = adapter.execControl("ROLLBACK")

proc safeSavepointName(name: string): string =
  if name.len == 0:
    raise newException(ValueError, "Savepoint name cannot be empty")
  for character in name:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      raise newException(ValueError, "Unsafe savepoint name: " & name)
  "\"" & name & "\""

method savepoint*(adapter: SqliteDatabaseAdapter, name: string) =
  adapter.execControl("SAVEPOINT " & safeSavepointName(name))

method rollbackToSavepoint*(adapter: SqliteDatabaseAdapter, name: string) =
  adapter.execControl("ROLLBACK TO SAVEPOINT " & safeSavepointName(name))

method releaseSavepoint*(adapter: SqliteDatabaseAdapter, name: string) =
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
        statement.finalize())
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
      statement.finalize())
  some(name)
