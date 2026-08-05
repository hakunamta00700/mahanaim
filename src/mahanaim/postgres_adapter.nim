## PostgreSQL driver adapter backed by Nim's db_connector/libpq binding.
##
## The adapter owns only connection lifecycle and parameter transport. Query
## intent, identifier validation, and migration shape remain in database.nim,
## which keeps the SQLite and PostgreSQL implementations interchangeable.

import std/[options, strutils]
import pkg/db_connector/[db_postgres, postgres]
import ./database

type
  PostgresDatabaseAdapter* = ref object of DatabaseAdapter
    ## One adapter maps to one libpq connection. Pooling is deliberately kept
    ## outside this type so a transaction never silently changes connections.
    connection*: db_postgres.DbConn
    endpoint*: string
    nextStatementId: int

proc newPostgresDatabaseAdapter*(connection, user, password, database: string):
    PostgresDatabaseAdapter =
  ## Open a libpq connection with credentials supplied by the caller/config.
  if connection.strip().len == 0 or database.strip().len == 0:
    raise newException(ValueError,
      "PostgreSQL connection and database are required")
  result = PostgresDatabaseAdapter(dialect: dialectPostgres,
    capabilities: capabilitiesForDialect(dialectPostgres),
    connection: db_postgres.open(connection, user, password, database),
    endpoint: connection, nextStatementId: 0)

proc close*(adapter: PostgresDatabaseAdapter) =
  ## Shutdown hooks may call close more than once, so make it idempotent.
  if not adapter.isNil and not adapter.connection.isNil:
    adapter.connection.close()
    adapter.connection = nil

proc valueText(value: SqlValue): string =
  ## Convert values to PostgreSQL text protocol representation. NULL is kept
  ## separate by bindParameters and is sent as a nil libpq parameter pointer.
  case value.kind
  of sqlNull: ""
  of sqlText: value.text
  of sqlInteger: $value.integer
  of sqlFloat: $value.floating
  of sqlBoolean:
    if value.boolean: "true" else: "false"
  of sqlList:
    raise newException(ValueError, "PostgreSQL bind received an unexpanded list")

proc bindParameters(parameters: seq[SqlValue]):
    tuple[values: cstringArray, allocated: seq[pointer]] =
  ## libpq accepts a nil entry for SQL NULL. Each non-null string receives an
  ## owned C buffer so the array remains valid until PQexecParams returns.
  result.values = cast[cstringArray](alloc0(
    max(1, parameters.len) * sizeof(cstring)))
  result.allocated = @[]
  for index, parameter in parameters:
    if parameter.kind == sqlNull:
      result.values[index] = nil
      continue
    let text = valueText(parameter)
    let buffer = alloc0(text.len + 1)
    copyMem(buffer, text.cstring, text.len)
    result.values[index] = cast[cstring](buffer)
    result.allocated.add(buffer)

proc releaseParameters(values: cstringArray,
                       allocated: seq[pointer]) =
  ## Release both the individual C strings and the pointer array after libpq
  ## has consumed them.
  for buffer in allocated:
    dealloc(buffer)
  dealloc(values)

proc postgresValueKindForOid*(oid: int): SqlValueKind =
  ## libpq reports PostgreSQL's stable type OID for every result column. Keep
  ## this mapping pure and small so compile-only tests can pin the neutral
  ## boundary without requiring a running PostgreSQL server.
  case oid
  of 16: sqlBoolean                 # bool
  of 20, 21, 23, 26: sqlInteger      # int8, int2, int4, oid
  of 700, 701, 1700: sqlFloat       # float4, float8, numeric
  else: sqlText                     # dates, UUID, JSON, and extensions

proc postgresColumnMetadataForOid*(name: string, oid: int):
    DatabaseColumnMetadata =
  ## Keep OID-to-column metadata construction pure so applications and compile
  ## contract tests can reason about the neutral result boundary without a
  ## running server. The live response path supplies the actual libpq name.
  if name.strip().len == 0:
    raise newException(ValueError, "PostgreSQL result column name is required")
  DatabaseColumnMetadata(name: name, kind: postgresValueKindForOid(oid),
    backendTypeId: oid)

proc postgresValueForOid(value: string, oid: int): SqlValue =
  ## Convert only unambiguous scalar OIDs. Values that do not parse are kept as
  ## text rather than being silently coerced into a misleading JSON number.
  case postgresValueKindForOid(oid)
  of sqlBoolean:
    booleanValue(value.toLowerAscii() in ["t", "true", "1", "yes"])
  of sqlInteger:
    try: integerValue(parseInt(value).int64)
    except ValueError: textValue(value)
  of sqlFloat:
    try: floatValue(parseFloat(value))
    except ValueError: textValue(value)
  else: textValue(value)

method executeResult*(adapter: PostgresDatabaseAdapter,
                      query: CompiledQuery): DatabaseResult {.gcsafe.} =
  ## Execute one parameterized command/query through libpq's extended query
  ## protocol. Values never get interpolated into SQL source text. Metadata is
  ## captured from the same PGresult as rows so aliases and typed scalars can
  ## never drift apart between separate executions.
  if adapter.isNil or adapter.connection.isNil:
    raise newException(ValueError, "PostgreSQL adapter is closed")
  if query.sql.strip().len == 0:
    raise newException(ValueError, "PostgreSQL query cannot be empty")
  let bound = bindParameters(query.parameters)
  try:
    let response = pqexecParams(adapter.connection, query.sql.cstring,
      query.parameters.len.int32, nil, bound.values, nil, nil, 0)
    if response.isNil:
      raise newException(CatchableError,
        "PostgreSQL returned no result: " & $pqerrorMessage(adapter.connection))
    defer: pqclear(response)
    let status = pqresultStatus(response)
    if status notin {PGRES_COMMAND_OK, PGRES_TUPLES_OK}:
      raise newException(CatchableError,
        "PostgreSQL query failed: " & $pqresultErrorMessage(response))
    if status == PGRES_TUPLES_OK:
      for columnIndex in 0 ..< pqnfields(response).int:
        let oid = pqftype(response, columnIndex.int32).int
        result.columns.add(postgresColumnMetadataForOid(
          $pqfname(response, columnIndex.int32), oid))
      for rowIndex in 0 ..< pqntuples(response).int:
        var row: seq[SqlValue] = @[]
        for columnIndex in 0 ..< pqnfields(response).int:
          if pqgetisnull(response, rowIndex.int32, columnIndex.int32) != 0:
            row.add(nullValue())
          else:
            let oid = pqftype(response, columnIndex.int32).int
            row.add(postgresValueForOid($pqgetvalue(response,
              rowIndex.int32, columnIndex.int32), oid))
        result.rows.add(row)
      if statementMutatesRows(query.sql):
        ## PostgreSQL DML with RETURNING reports one tuple per affected row;
        ## command-only DML is handled by PQcmdTuples below.
        result.affectedRows = result.rows.len
    elif status == PGRES_COMMAND_OK:
      let tupleCount = $pqcmdTuples(response)
      if tupleCount.len > 0:
        try:
          result.affectedRows = parseInt(tupleCount)
        except ValueError:
          result.affectedRows = 0
  finally:
    releaseParameters(bound.values, bound.allocated)

method execute*(adapter: PostgresDatabaseAdapter,
                query: CompiledQuery): seq[seq[SqlValue]] {.gcsafe.} =
  ## Preserve the original row-only API while using one metadata-aware wire
  ## execution path. This avoids duplicate binding and response parsing logic.
  adapter.executeResult(query).rows

proc execControl(adapter: PostgresDatabaseAdapter, statement: string) {.gcsafe.} =
  ## Transaction and savepoint statements contain only framework-generated
  ## identifiers, but still use the common execute boundary for consistency.
  discard adapter.execute(CompiledQuery(sql: statement, parameters: @[]))

method begin*(adapter: PostgresDatabaseAdapter) {.gcsafe.} =
  adapter.execControl("BEGIN")

method commit*(adapter: PostgresDatabaseAdapter) {.gcsafe.} =
  adapter.execControl("COMMIT")

method rollback*(adapter: PostgresDatabaseAdapter) {.gcsafe.} =
  adapter.execControl("ROLLBACK")

proc safeSavepointName(name: string): string =
  if name.len == 0:
    raise newException(ValueError, "Savepoint name cannot be empty")
  for character in name:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      raise newException(ValueError, "Unsafe savepoint name: " & name)
  "\"" & name & "\""

method savepoint*(adapter: PostgresDatabaseAdapter, name: string) {.gcsafe.} =
  adapter.execControl("SAVEPOINT " & safeSavepointName(name))

method rollbackToSavepoint*(adapter: PostgresDatabaseAdapter, name: string) {.gcsafe.} =
  adapter.execControl("ROLLBACK TO SAVEPOINT " & safeSavepointName(name))

method releaseSavepoint*(adapter: PostgresDatabaseAdapter, name: string) {.gcsafe.} =
  adapter.execControl("RELEASE SAVEPOINT " & safeSavepointName(name))

proc isolationSql(level: TransactionIsolationLevel): string =
  case level
  of isolationReadCommitted: "READ COMMITTED"
  of isolationRepeatableRead: "REPEATABLE READ"
  of isolationSerializable: "SERIALIZABLE"

method setIsolationLevel*(adapter: PostgresDatabaseAdapter,
                          level: TransactionIsolationLevel) {.gcsafe.} =
  ## PostgreSQL requires this command inside a transaction; callers therefore
  ## set isolation immediately after DatabaseSession.begin().
  if level notin adapter.capabilities.isolationLevels:
    raise newException(ValueError,
      "PostgreSQL adapter does not support requested isolation level")
  adapter.execControl("SET TRANSACTION ISOLATION LEVEL " & isolationSql(level))

proc applyMigration*(adapter: PostgresDatabaseAdapter, migration: Migration) =
  ## Apply one migration atomically using PostgreSQL's transactional DDL. The
  ## operation compiler remains backend-neutral; only the adapter owns the
  ## connection and transaction boundary.
  if adapter.isNil:
    raise newException(ValueError, "PostgreSQL migration adapter is required")
  let currentMigration = migration
  adapter.withTransaction(proc() =
    for operation in currentMigration.up:
      discard adapter.execute(CompiledQuery(
        sql: migrationSql(operation, dialectPostgres), parameters: @[])))

proc rollbackMigration*(adapter: PostgresDatabaseAdapter,
                        migration: Migration) =
  ## Down operations use the same rollback boundary as up operations. A failed
  ## step therefore leaves both schema and migration history unchanged.
  if adapter.isNil:
    raise newException(ValueError, "PostgreSQL migration adapter is required")
  let currentMigration = migration
  adapter.withTransaction(proc() =
    for operation in currentMigration.down:
      discard adapter.execute(CompiledQuery(
        sql: migrationSql(operation, dialectPostgres), parameters: @[])))

const postgresMigrationTable = "__mahanaim_migrations"
const postgresMigrationLockExpression =
  "SELECT pg_advisory_xact_lock(hashtext('mahanaim:migrations'))"

proc acquireMigrationLock(adapter: PostgresDatabaseAdapter) =
  ## Serialize migration runners across independent PostgreSQL connections.
  ## The lock is transaction-scoped, so a crashed or closed runner cannot
  ## leave a process-global mutex behind. SQLite relies on its write lock;
  ## PostgreSQL needs this explicit coordination because DDL transactions can
  ## otherwise observe the same empty history before either insert commits.
  discard adapter.execute(CompiledQuery(sql: postgresMigrationLockExpression,
    parameters: @[]))

proc ensureMigrationTable(adapter: PostgresDatabaseAdapter) =
  ## BIGSERIAL preserves execution order across independent connections while
  ## the unique name keeps repeated `migrate` calls idempotent.
  discard adapter.execute(CompiledQuery(sql:
    "CREATE TABLE IF NOT EXISTS \"" & postgresMigrationTable &
    "\" (\"sequence\" BIGSERIAL PRIMARY KEY, \"name\" TEXT NOT NULL UNIQUE)",
    parameters: @[]))

proc appliedMigrations*(adapter: PostgresDatabaseAdapter): seq[string] =
  ## Return migration names in the order committed by PostgreSQL.
  if adapter.isNil:
    raise newException(ValueError, "PostgreSQL migration adapter is required")
  adapter.ensureMigrationTable()
  let rows = adapter.execute(CompiledQuery(sql:
    "SELECT \"name\" FROM \"" & postgresMigrationTable &
    "\" ORDER BY \"sequence\"", parameters: @[]))
  for row in rows:
    if row.len > 0:
      result.add(row[0].text)

proc validatePostgresMigrations(migrations: openArray[Migration]) =
  ## Validate the complete list before changing the database so duplicate
  ## names cannot leave a partially applied history.
  var names: seq[string] = @[]
  for migration in migrations:
    if migration.name.strip().len == 0:
      raise newException(ValueError, "Migration name cannot be empty")
    if migration.name in names:
      raise newException(ValueError, "Duplicate migration: " & migration.name)
    names.add(migration.name)

proc migrate*(adapter: PostgresDatabaseAdapter,
              migrations: openArray[Migration]): seq[string] =
  ## Apply only pending migrations and record each name in the same commit.
  ## Acquire the advisory lock before reading history so concurrent runners
  ## cannot both decide that the same migration is still pending.
  if adapter.isNil:
    raise newException(ValueError, "PostgreSQL migration adapter is required")
  validatePostgresMigrations(migrations)
  ## Own the migration list before capturing it in the transaction callback;
  ## the public openArray view may belong to a caller's temporary sequence.
  let ownedMigrations = @migrations
  var appliedNames: seq[string] = @[]
  adapter.withTransaction(proc() =
    adapter.acquireMigrationLock()
    adapter.ensureMigrationTable()
    let applied = adapter.appliedMigrations()
    for migration in ownedMigrations:
      if migration.name in applied:
        continue
      let currentMigration = migration
      for operation in currentMigration.up:
        discard adapter.execute(CompiledQuery(
          sql: migrationSql(operation, dialectPostgres), parameters: @[]))
      discard adapter.execute(CompiledQuery(
        sql: "INSERT INTO \"" & postgresMigrationTable &
          "\" (\"name\") VALUES ($1)",
        parameters: @[textValue(currentMigration.name)]))
      appliedNames.add(currentMigration.name))
  result = appliedNames

proc rollbackLatest*(adapter: PostgresDatabaseAdapter,
                     migrations: openArray[Migration]): Option[string] =
  ## Roll back exactly the latest recorded migration, preserving stack order.
  if adapter.isNil:
    raise newException(ValueError, "PostgreSQL migration adapter is required")
  validatePostgresMigrations(migrations)
  adapter.ensureMigrationTable()
  let rows = adapter.execute(CompiledQuery(sql:
    "SELECT \"name\" FROM \"" & postgresMigrationTable &
    "\" ORDER BY \"sequence\" DESC LIMIT 1", parameters: @[]))
  if rows.len == 0 or rows[0].len == 0:
    return none(string)
  let name = rows[0][0].text
  var selected = none(Migration)
  for migration in migrations:
    if migration.name == name:
      selected = some(migration)
      break
  if selected.isNone:
    raise newException(ValueError, "Migration definition is missing: " & name)
  let currentMigration = selected.get()
  adapter.withTransaction(proc() =
    for operation in currentMigration.down:
      discard adapter.execute(CompiledQuery(
        sql: migrationSql(operation, dialectPostgres), parameters: @[]))
    discard adapter.execute(CompiledQuery(
      sql: "DELETE FROM \"" & postgresMigrationTable & "\" WHERE \"name\" = $1",
      parameters: @[textValue(name)])))
  some(name)
