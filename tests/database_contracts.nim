## Shared database adapter contract assertions.
##
## The helper intentionally accepts only DatabaseAdapter. Backend-specific
## fixtures own connection credentials and cleanup, while this module owns the
## meaning that SQLite and PostgreSQL must share: bound values, CRUD result
## shape, and affected-row accounting.

import mahanaim/database

proc runCommonDatabaseContract*(adapter: DatabaseAdapter, tableName: string) =
  ## Table names are supplied by tests, never by request input; adapters still
  ## receive only framework-generated SQL identifiers at this boundary.
  if adapter.isNil or tableName.len == 0:
    raise newException(ValueError, "Database contract requires an adapter and table")
  let placeholder = if adapter.dialect == dialectPostgres: "$1" else: "?"
  discard adapter.execute(CompiledQuery(sql:
    "DROP TABLE IF EXISTS \"" & tableName & "\"", parameters: @[]))
  discard adapter.execute(CompiledQuery(sql:
    "CREATE TABLE \"" & tableName & "\" (\"id\" INTEGER, \"value\" TEXT)",
    parameters: @[]))

  let inserted = adapter.executeResult(CompiledQuery(
    sql: "INSERT INTO \"" & tableName & "\" (\"id\", \"value\") VALUES (" &
      placeholder & ", " & (if adapter.dialect == dialectPostgres: "$2" else: "?") & ")",
    parameters: @[integerValue(1), textValue("shared-contract")]))
  doAssert inserted.affectedRows == 1

  let rows = adapter.execute(CompiledQuery(
    sql: "SELECT \"value\" FROM \"" & tableName & "\" WHERE \"id\" = " &
      placeholder,
    parameters: @[integerValue(1)]))
  doAssert rows.len == 1
  doAssert rows[0].len == 1
  doAssert rows[0][0].text == "shared-contract"

  let deleted = adapter.executeResult(CompiledQuery(
    sql: "DELETE FROM \"" & tableName & "\" WHERE \"id\" = " & placeholder,
    parameters: @[integerValue(1)]))
  doAssert deleted.affectedRows == 1
