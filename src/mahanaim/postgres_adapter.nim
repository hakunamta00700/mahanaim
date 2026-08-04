## PostgreSQL driver adapter backed by Nim's db_connector/libpq binding.
##
## The adapter owns only connection lifecycle and parameter transport. Query
## intent, identifier validation, and migration shape remain in database.nim,
## which keeps the SQLite and PostgreSQL implementations interchangeable.

import std/[strutils]
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

method execute*(adapter: PostgresDatabaseAdapter,
                query: CompiledQuery): seq[seq[SqlValue]] =
  ## Execute one parameterized command/query through libpq's extended query
  ## protocol. Values never get interpolated into SQL source text.
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
      for rowIndex in 0 ..< pqntuples(response).int:
        var row: seq[SqlValue] = @[]
        for columnIndex in 0 ..< pqnfields(response).int:
          if pqgetisnull(response, rowIndex.int32, columnIndex.int32) != 0:
            row.add(nullValue())
          else:
            row.add(textValue($pqgetvalue(response,
              rowIndex.int32, columnIndex.int32)))
        result.add(row)
  finally:
    releaseParameters(bound.values, bound.allocated)

proc execControl(adapter: PostgresDatabaseAdapter, statement: string) =
  ## Transaction and savepoint statements contain only framework-generated
  ## identifiers, but still use the common execute boundary for consistency.
  discard adapter.execute(CompiledQuery(sql: statement, parameters: @[]))

method begin*(adapter: PostgresDatabaseAdapter) =
  adapter.execControl("BEGIN")

method commit*(adapter: PostgresDatabaseAdapter) =
  adapter.execControl("COMMIT")

method rollback*(adapter: PostgresDatabaseAdapter) =
  adapter.execControl("ROLLBACK")

proc safeSavepointName(name: string): string =
  if name.len == 0:
    raise newException(ValueError, "Savepoint name cannot be empty")
  for character in name:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      raise newException(ValueError, "Unsafe savepoint name: " & name)
  "\"" & name & "\""

method savepoint*(adapter: PostgresDatabaseAdapter, name: string) =
  adapter.execControl("SAVEPOINT " & safeSavepointName(name))

method rollbackToSavepoint*(adapter: PostgresDatabaseAdapter, name: string) =
  adapter.execControl("ROLLBACK TO SAVEPOINT " & safeSavepointName(name))

method releaseSavepoint*(adapter: PostgresDatabaseAdapter, name: string) =
  adapter.execControl("RELEASE SAVEPOINT " & safeSavepointName(name))
