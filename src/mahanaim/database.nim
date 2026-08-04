## Backend-neutral database contracts.
##
## The framework owns query intent, parameter binding, migration shape, and
## transaction lifecycle.  A SQLite/PostgreSQL driver remains an adapter that
## executes the compiled statement; raw values are never interpolated into SQL.

import std/[strutils]
import ./models

type
  DatabaseDialect* = enum
    dialectSqlite
    dialectPostgres

  TransactionIsolationLevel* = enum
    isolationReadCommitted
    isolationRepeatableRead
    isolationSerializable

  DatabaseCapabilities* = object
    ## Explicit capability data prevents repositories from assuming that a
    ## PostgreSQL feature has identical SQLite semantics.
    supportsTransactions*: bool
    supportsSavepoints*: bool
    supportsTypedNulls*: bool
    supportsIsolation*: bool
    isolationLevels*: set[TransactionIsolationLevel]

  SqlValueKind* = enum
    sqlNull
    sqlText
    sqlInteger
    sqlFloat
    sqlBoolean

  SqlValue* = object
    case kind*: SqlValueKind
    of sqlNull: discard
    of sqlText: text*: string
    of sqlInteger: integer*: int64
    of sqlFloat: floating*: float
    of sqlBoolean: boolean*: bool

  FilterOperator* = enum
    filterEqual
    filterNotEqual
    filterGreater
    filterGreaterOrEqual
    filterLess
    filterLessOrEqual
    filterLike
    filterIsNull
    filterIsNotNull

  QueryFilter* = object
    field*: string
    operator*: FilterOperator
    value*: SqlValue

  QueryOrder* = object
    field*: string
    descending*: bool

  SelectQuery* = object
    table*: string
    columns*: seq[string]
    filters*: seq[QueryFilter]
    orderBy*: seq[QueryOrder]
    limit*: int
    offset*: int

  RelationJoinKind* = enum
    relationInnerJoin
    relationLeftJoin

  RelationJoin* = object
    ## A join is expressed as data so every backend shares validation and
    ## placeholder semantics instead of concatenating relation SQL in routes.
    kind*: RelationJoinKind
    table*: string
    alias*: string
    localTable*: string
    localField*: string
    foreignField*: string

  RelationSelectQuery* = object
    ## One-hop joins keep the core contract deterministic; nested loading can
    ## compose this shape later without embedding backend-specific SQL.
    table*: string
    alias*: string
    columns*: seq[string]
    joins*: seq[RelationJoin]
    filters*: seq[QueryFilter]
    orderBy*: seq[QueryOrder]
    limit*: int
    offset*: int

  Pagination* = object
    ## API-level pagination is translated to SQL only at the database boundary.
    page*: int
    pageSize*: int
    maxPageSize*: int

  CompiledQuery* = object
    sql*: string
    parameters*: seq[SqlValue]

  MigrationOperationKind* = enum
    migrationCreateTable
    migrationAddColumn
    migrationCreateIndex
    migrationDropTable

  MigrationOperation* = object
    kind*: MigrationOperationKind
    table*: string
    field*: ModelField
    index*: ModelIndex

  Migration* = object
    name*: string
    up*: seq[MigrationOperation]
    down*: seq[MigrationOperation]

  DatabaseAdapter* = ref object of RootObj
    ## Driver adapters implement execution and transaction methods here.
    dialect*: DatabaseDialect
    capabilities*: DatabaseCapabilities

  ## Transactions execute on the caller's connection thread; callbacks do
  ## not cross a worker boundary and therefore need no artificial gcsafe
  ## restriction that would prevent adapters from being captured safely.
  TransactionCallback* = proc ()

method execute*(adapter: DatabaseAdapter,
                query: CompiledQuery): seq[seq[SqlValue]] {.base.} =
  discard adapter
  discard query
  raise newException(ValueError, "Database adapter does not implement execute")

method begin*(adapter: DatabaseAdapter) {.base.} =
  discard adapter
  raise newException(ValueError, "Database adapter does not implement begin")

method commit*(adapter: DatabaseAdapter) {.base.} =
  discard adapter
  raise newException(ValueError, "Database adapter does not implement commit")

method rollback*(adapter: DatabaseAdapter) {.base.} =
  discard adapter
  raise newException(ValueError, "Database adapter does not implement rollback")

method savepoint*(adapter: DatabaseAdapter, name: string) {.base.} =
  ## Drivers may map this to SAVEPOINT; the base contract fails explicitly.
  discard adapter
  discard name
  raise newException(ValueError, "Database adapter does not implement savepoint")

method rollbackToSavepoint*(adapter: DatabaseAdapter, name: string) {.base.} =
  discard adapter
  discard name
  raise newException(ValueError,
    "Database adapter does not implement rollbackToSavepoint")

method releaseSavepoint*(adapter: DatabaseAdapter, name: string) {.base.} =
  discard adapter
  discard name
  raise newException(ValueError,
    "Database adapter does not implement releaseSavepoint")

proc capabilitiesForDialect*(dialect: DatabaseDialect): DatabaseCapabilities =
  ## This matrix is conservative: a capability is advertised only when the
  ## common adapter contract can preserve its semantics on that backend.
  case dialect
  of dialectSqlite:
    DatabaseCapabilities(
      supportsTransactions: true,
      supportsSavepoints: true,
      supportsTypedNulls: true,
      supportsIsolation: false,
      isolationLevels: {})
  of dialectPostgres:
    DatabaseCapabilities(
      supportsTransactions: true,
      supportsSavepoints: true,
      supportsTypedNulls: true,
      supportsIsolation: true,
      isolationLevels: {isolationReadCommitted, isolationRepeatableRead,
                        isolationSerializable})

method setIsolationLevel*(adapter: DatabaseAdapter,
                          level: TransactionIsolationLevel) {.base.} =
  ## Drivers opt in explicitly; silent emulation would make transaction safety
  ## depend on the backend selected at deployment time.
  if adapter.isNil or not adapter.capabilities.supportsIsolation or
      level notin adapter.capabilities.isolationLevels:
    raise newException(ValueError,
      "Database adapter does not support requested isolation level")
  discard level

proc withTransaction*(adapter: DatabaseAdapter,
                      operation: TransactionCallback) =
  ## Centralize the all-or-rollback rule so every backend has the same failure
  ## semantics. Persistence adapters can expose richer transaction objects
  ## while retaining this safe convenience boundary.
  if adapter.isNil or operation.isNil:
    raise newException(ValueError, "Transaction adapter and operation are required")
  adapter.begin()
  try:
    operation()
    adapter.commit()
  except CatchableError:
    adapter.rollback()
    raise

proc textValue*(value: string): SqlValue = SqlValue(kind: sqlText, text: value)
proc integerValue*(value: int64): SqlValue = SqlValue(kind: sqlInteger, integer: value)
proc floatValue*(value: float): SqlValue = SqlValue(kind: sqlFloat, floating: value)
proc booleanValue*(value: bool): SqlValue = SqlValue(kind: sqlBoolean, boolean: value)
proc nullValue*(): SqlValue = SqlValue(kind: sqlNull)

proc quoteIdentifier(value: string): string =
  ## Strict identifiers make table/column names safe without trusting callers.
  if value.len == 0:
    raise newException(ValueError, "SQL identifier cannot be empty")
  for character in value:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      raise newException(ValueError, "Unsafe SQL identifier: " & value)
  "\"" & value & "\""

proc operatorSql(operator: FilterOperator): string =
  case operator
  of filterEqual: " = "
  of filterNotEqual: " <> "
  of filterGreater: " > "
  of filterGreaterOrEqual: " >= "
  of filterLess: " < "
  of filterLessOrEqual: " <= "
  of filterLike: " LIKE "
  of filterIsNull: " IS NULL"
  of filterIsNotNull: " IS NOT NULL"

proc compileSelect*(query: SelectQuery,
                    dialect = dialectSqlite): CompiledQuery =
  ## Compile intent and values separately so every driver can bind parameters.
  if query.table.len == 0 or query.columns.len == 0:
    raise newException(ValueError, "SELECT requires a table and columns")
  if query.limit < 0 or query.offset < 0:
    raise newException(ValueError, "Query limit and offset cannot be negative")
  result.sql = "SELECT "
  var selected: seq[string] = @[]
  for column in query.columns:
    selected.add(quoteIdentifier(column))
  result.sql.add(selected.join(", "))
  result.sql.add(" FROM " & quoteIdentifier(query.table))
  var parameterIndex = 0
  for index, filter in query.filters:
    if filter.field.len == 0:
      raise newException(ValueError, "Filter field cannot be empty")
    result.sql.add(if index == 0: " WHERE " else: " AND ")
    result.sql.add(quoteIdentifier(filter.field) & operatorSql(filter.operator))
    if filter.operator notin {filterIsNull, filterIsNotNull}:
      inc parameterIndex
      result.sql.add(if dialect == dialectPostgres: "$" & $parameterIndex else: "?")
      result.parameters.add(filter.value)
  if query.orderBy.len > 0:
    var orders: seq[string] = @[]
    for order in query.orderBy:
      orders.add(quoteIdentifier(order.field) & (if order.descending: " DESC" else: " ASC"))
    result.sql.add(" ORDER BY " & orders.join(", "))
  if query.limit > 0:
    result.sql.add(" LIMIT " & $query.limit)
  if query.offset > 0:
      result.sql.add(" OFFSET " & $query.offset)

proc quoteQualifiedIdentifier(value: string): string =
  ## Qualify table/alias columns while applying the same strict identifier
  ## whitelist as ordinary SELECT queries.
  let parts = value.split('.')
  if parts.len != 2:
    raise newException(ValueError, "Qualified identifier requires table.field")
  quoteIdentifier(parts[0]) & "." & quoteIdentifier(parts[1])

proc compileRelationSelect*(query: RelationSelectQuery,
                            dialect = dialectSqlite): CompiledQuery =
  ## Compile a deterministic one-hop relation query with bound filters.
  if query.table.len == 0 or query.columns.len == 0:
    raise newException(ValueError, "Relation SELECT requires a table and columns")
  if query.limit < 0 or query.offset < 0:
    raise newException(ValueError, "Query limit and offset cannot be negative")
  let baseAlias = if query.alias.len > 0: query.alias else: query.table
  result.sql = "SELECT "
  var selected: seq[string] = @[]
  for column in query.columns:
    selected.add(quoteQualifiedIdentifier(
      if column.contains('.'): column else: baseAlias & "." & column))
  result.sql.add(selected.join(", "))
  result.sql.add(" FROM " & quoteIdentifier(query.table))
  if query.alias.len > 0:
    result.sql.add(" AS " & quoteIdentifier(query.alias))
  var knownAliases = @[baseAlias]
  for join in query.joins:
    if join.table.len == 0 or join.localTable.len == 0 or
        join.localField.len == 0 or join.foreignField.len == 0:
      raise newException(ValueError, "Relation join requires table and fields")
    let joinAlias = if join.alias.len > 0: join.alias else: join.table
    if joinAlias in knownAliases:
      raise newException(ValueError, "Duplicate relation join alias: " & joinAlias)
    knownAliases.add(joinAlias)
    let joinWord = if join.kind == relationLeftJoin: " LEFT JOIN " else: " INNER JOIN "
    result.sql.add(joinWord & quoteIdentifier(join.table))
    if join.alias.len > 0:
      result.sql.add(" AS " & quoteIdentifier(join.alias))
    result.sql.add(" ON " & quoteQualifiedIdentifier(join.localTable & "." & join.localField) &
      " = " & quoteQualifiedIdentifier(joinAlias & "." & join.foreignField))
  var parameterIndex = 0
  for index, filter in query.filters:
    if filter.field.len == 0:
      raise newException(ValueError, "Filter field cannot be empty")
    result.sql.add(if index == 0: " WHERE " else: " AND ")
    let field = if filter.field.contains('.'): filter.field else:
      baseAlias & "." & filter.field
    result.sql.add(quoteQualifiedIdentifier(field) & operatorSql(filter.operator))
    if filter.operator notin {filterIsNull, filterIsNotNull}:
      inc parameterIndex
      result.sql.add(if dialect == dialectPostgres: "$" & $parameterIndex else: "?")
      result.parameters.add(filter.value)
  if query.orderBy.len > 0:
    var orders: seq[string] = @[]
    for order in query.orderBy:
      let field = if order.field.contains('.'): order.field else:
        baseAlias & "." & order.field
      orders.add(quoteQualifiedIdentifier(field) &
        (if order.descending: " DESC" else: " ASC"))
    result.sql.add(" ORDER BY " & orders.join(", "))
  if query.limit > 0:
    result.sql.add(" LIMIT " & $query.limit)
  if query.offset > 0:
    result.sql.add(" OFFSET " & $query.offset)

proc newPagination*(page = 1, pageSize = 20,
                     maxPageSize = 100): Pagination =
  ## Reject invalid client input before it can produce unbounded queries.
  if page < 1:
    raise newException(ValueError, "Pagination page must be at least 1")
  if pageSize < 1:
    raise newException(ValueError, "Pagination page size must be positive")
  if maxPageSize < 1 or pageSize > maxPageSize:
    raise newException(ValueError, "Pagination page size exceeds configured maximum")
  Pagination(page: page, pageSize: pageSize, maxPageSize: maxPageSize)

proc withPagination*(query: SelectQuery,
                     pagination: Pagination): SelectQuery =
  ## Copy the query so callers can reuse an unpaged base for multiple clients.
  if pagination.page < 1 or pagination.pageSize < 1 or
      pagination.pageSize > pagination.maxPageSize:
    raise newException(ValueError, "Invalid pagination contract")
  result = query
  result.limit = pagination.pageSize
  result.offset = (pagination.page - 1) * pagination.pageSize

proc migrationSql*(operation: MigrationOperation,
                   dialect = dialectSqlite): string =
  ## A small deterministic compiler is useful for review and driver adapters.
  discard dialect
  case operation.kind
  of migrationCreateTable:
    if operation.table.len == 0: raise newException(ValueError, "Table is required")
    "CREATE TABLE " & quoteIdentifier(operation.table) & " (" &
      quoteIdentifier(operation.field.name) & " TEXT)"
  of migrationAddColumn:
    "ALTER TABLE " & quoteIdentifier(operation.table) & " ADD COLUMN " &
      quoteIdentifier(operation.field.name) & " TEXT"
  of migrationCreateIndex:
    if operation.index.fields.len == 0: raise newException(ValueError, "Index needs fields")
    var fields: seq[string] = @[]
    for field in operation.index.fields: fields.add(quoteIdentifier(field))
    "CREATE " & (if operation.index.unique: "UNIQUE " else: "") & "INDEX " &
      quoteIdentifier(operation.index.name) & " ON " & quoteIdentifier(operation.table) &
      " (" & fields.join(", ") & ")"
  of migrationDropTable:
    "DROP TABLE " & quoteIdentifier(operation.table)
