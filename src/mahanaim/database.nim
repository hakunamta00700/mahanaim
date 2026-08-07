## Backend-neutral database contracts.
##
## The framework owns query intent, parameter binding, migration shape, and
## transaction lifecycle.  A SQLite/PostgreSQL driver remains an adapter that
## executes the compiled statement; raw values are never interpolated into SQL.

import std/[strutils, tables]
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
    supportsRowLocks*: bool

  SqlValueKind* = enum
    sqlNull
    sqlText
    sqlInteger
    sqlFloat
    sqlBoolean
    ## A list is query-builder state only; the compiler expands it into bound
    ## scalar parameters before any adapter receives a CompiledQuery.
    sqlList

  SqlValue* = object
    case kind*: SqlValueKind
    of sqlNull: discard
    of sqlText: text*: string
    of sqlInteger: integer*: int64
    of sqlFloat: floating*: float
    of sqlBoolean: boolean*: bool
    of sqlList: values*: seq[SqlValue]

  DatabaseColumnMetadata* = object
    ## Result metadata is kept separate from row values so callers can inspect
    ## aliases and backend types without guessing from the first row. The
    ## backend type id is optional and is primarily useful for adapter-specific
    ## diagnostics such as PostgreSQL's libpq OID.
    name*: string
    kind*: SqlValueKind
    backendTypeId*: int

  DatabaseResult* = object
    ## A single execution result keeps column order and row order together.
    ## Existing `execute` callers remain source-compatible; new consumers can
    ## opt into metadata through `executeResult`. DML callers also receive a
    ## backend-neutral affected-row count instead of parsing driver output.
    columns*: seq[DatabaseColumnMetadata]
    rows*: seq[seq[SqlValue]]
    affectedRows*: int

  FilterOperator* = enum
    filterEqual
    filterNotEqual
    filterGreater
    filterGreaterOrEqual
    filterLess
    filterLessOrEqual
    filterLike
    filterIn
    filterIsNull
    filterIsNotNull

  QueryFilter* = object
    field*: string
    operator*: FilterOperator
    value*: SqlValue

  QueryOrder* = object
    field*: string
    descending*: bool

  QueryAggregateFunction* = enum
    aggregateCount
    aggregateSum
    aggregateAverage
    aggregateMinimum
    aggregateMaximum

  QueryAggregate* = object
    ## Aggregate intent is data, so the same expression can be compiled for
    ## SQLite and PostgreSQL without allowing route code to build SQL text.
    function*: QueryAggregateFunction
    field*: string
    alias*: string

  QueryAnnotationFunction* = enum
    ## Typed arithmetic keeps computed projections safe and backend-neutral.
    annotationAdd
    annotationSubtract
    annotationMultiply
    annotationDivide

  QueryAnnotation* = object
    leftField*: string
    rightField*: string
    function*: QueryAnnotationFunction
    alias*: string

  QueryLockMode* = enum
    lockNone
    lockForUpdate
    lockForShare

  SelectQuery* = object
    table*: string
    columns*: seq[string]
    filters*: seq[QueryFilter]
    orderBy*: seq[QueryOrder]
    limit*: int
    offset*: int
    aggregates*: seq[QueryAggregate]
    annotations*: seq[QueryAnnotation]
    groupBy*: seq[string]
    lockMode*: QueryLockMode

  QuerySet* = object
    ## Immutable-style builder around SelectQuery. Every builder operation
    ## returns a copy, allowing a base query to be safely reused by callers.
    query*: SelectQuery

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

  RawSqlQuery* = object
    ## Raw SQL is an explicit application escape hatch. The text remains
    ## caller-owned, but every value must still cross the adapter as a bound
    ## `SqlValue`; interpolation helpers are deliberately not provided.
    sql*: string
    parameters*: seq[SqlValue]

  DatabaseRole* = enum
    databaseRead
    databaseWrite

  DatabaseRouter* = ref object
    ## Multi-database routing is opt-in. A missing role fails explicitly rather
    ## than silently sending writes to a read replica or a default connection.
    adapters: Table[DatabaseRole, DatabaseAdapter]

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
                query: CompiledQuery): seq[seq[SqlValue]] {.base, gcsafe.} =
  discard adapter
  discard query
  raise newException(ValueError, "Database adapter does not implement execute")

method executeResult*(adapter: DatabaseAdapter,
                      query: CompiledQuery): DatabaseResult {.base, gcsafe.} =
  ## Compatibility extension for adapters that can expose result metadata.
  ## The base implementation deliberately preserves the old row-only contract
  ## so third-party adapters do not break when the framework adds metadata.
  result.rows = adapter.execute(query)

proc newRawSqlQuery*(sql: string,
                     parameters: openArray[SqlValue] = []): RawSqlQuery =
  let normalized = sql.strip()
  if normalized.len == 0 or normalized.contains({'\0', '\r', '\n'}):
    raise newException(ValueError, "Raw SQL must be a single non-empty statement")
  if normalized.count(';') > 1 or (normalized.count(';') == 1 and
      not normalized.endsWith(";")):
    raise newException(ValueError, "Raw SQL must contain one statement")
  result.sql = normalized
  result.parameters = @parameters

proc executeRaw*(adapter: DatabaseAdapter, query: RawSqlQuery): DatabaseResult =
  ## Do not offer a string interpolation overload: the explicit `SqlValue`
  ## list is the only supported channel for untrusted values.
  if adapter.isNil:
    raise newException(ValueError, "Database adapter is required for raw SQL")
  adapter.executeResult(CompiledQuery(sql: query.sql, parameters: query.parameters))

proc newDatabaseRouter*(): DatabaseRouter =
  DatabaseRouter(adapters: initTable[DatabaseRole, DatabaseAdapter]())

proc registerDatabase*(router: DatabaseRouter, role: DatabaseRole,
                       adapter: DatabaseAdapter) =
  if router.isNil or adapter.isNil:
    raise newException(ValueError, "Database router and adapter are required")
  if router.adapters.hasKey(role):
    raise newException(ValueError, "Database role is already configured")
  router.adapters[role] = adapter

proc databaseFor*(router: DatabaseRouter, role: DatabaseRole): DatabaseAdapter =
  if router.isNil or not router.adapters.hasKey(role):
    let name = if role == databaseRead: "read" else: "write"
    raise newException(ValueError, "Database routing is unsupported for " & name & " role")
  router.adapters[role]

proc executeRaw*(router: DatabaseRouter, role: DatabaseRole,
                 query: RawSqlQuery): DatabaseResult =
  router.databaseFor(role).executeRaw(query)

proc statementKeyword*(sql: string): string =
  ## Keep DML classification in the common contract so adapters agree on
  ## when `DatabaseResult.affectedRows` is meaningful. This intentionally
  ## recognizes only top-level conventional DML; adapters still own dialect
  ## specific execution and RETURNING behavior.
  let tokens = sql.strip().splitWhitespace()
  if tokens.len == 0:
    return ""
  tokens[0].toUpperAscii()

proc statementMutatesRows*(sql: string): bool =
  ## A small explicit set avoids treating SELECT/DDL command status as row
  ## mutations while preserving a predictable extension point for adapters.
  statementKeyword(sql) in ["INSERT", "UPDATE", "DELETE", "REPLACE"]

method begin*(adapter: DatabaseAdapter) {.base, gcsafe.} =
  discard adapter
  raise newException(ValueError, "Database adapter does not implement begin")

method commit*(adapter: DatabaseAdapter) {.base, gcsafe.} =
  discard adapter
  raise newException(ValueError, "Database adapter does not implement commit")

method rollback*(adapter: DatabaseAdapter) {.base, gcsafe.} =
  discard adapter
  raise newException(ValueError, "Database adapter does not implement rollback")

method savepoint*(adapter: DatabaseAdapter, name: string) {.base, gcsafe.} =
  ## Drivers may map this to SAVEPOINT; the base contract fails explicitly.
  discard adapter
  discard name
  raise newException(ValueError, "Database adapter does not implement savepoint")

method rollbackToSavepoint*(adapter: DatabaseAdapter, name: string) {.base, gcsafe.} =
  discard adapter
  discard name
  raise newException(ValueError,
    "Database adapter does not implement rollbackToSavepoint")

method releaseSavepoint*(adapter: DatabaseAdapter, name: string) {.base, gcsafe.} =
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
      isolationLevels: {},
      supportsRowLocks: false)
  of dialectPostgres:
    DatabaseCapabilities(
      supportsTransactions: true,
      supportsSavepoints: true,
      supportsTypedNulls: true,
      supportsIsolation: true,
      isolationLevels: {isolationReadCommitted, isolationRepeatableRead,
                        isolationSerializable},
      supportsRowLocks: true)

method setIsolationLevel*(adapter: DatabaseAdapter,
                          level: TransactionIsolationLevel) {.base, gcsafe.} =
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
proc listValue*(values: openArray[SqlValue]): SqlValue =
  ## Keep list members typed so every expanded item remains bound safely.
  SqlValue(kind: sqlList, values: @values)

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
  of filterIn: " IN "
  of filterIsNull: " IS NULL"
  of filterIsNotNull: " IS NOT NULL"

proc aggregateSql(function: QueryAggregateFunction): string =
  case function
  of aggregateCount: "COUNT"
  of aggregateSum: "SUM"
  of aggregateAverage: "AVG"
  of aggregateMinimum: "MIN"
  of aggregateMaximum: "MAX"

proc annotationSql(function: QueryAnnotationFunction): string =
  case function
  of annotationAdd: " + "
  of annotationSubtract: " - "
  of annotationMultiply: " * "
  of annotationDivide: " / "

proc withPagination*(query: SelectQuery,
                     pagination: Pagination): SelectQuery

proc compileSelect*(query: SelectQuery,
                    dialect = dialectSqlite): CompiledQuery

proc newQuerySet*(table: string): QuerySet =
  ## Start a query with no implicit projection; callers must choose fields or
  ## aggregates before compilation, preventing accidental SELECT * behavior.
  if table.len == 0:
    raise newException(ValueError, "QuerySet table is required")
  QuerySet(query: SelectQuery(table: table, columns: @[], filters: @[],
    orderBy: @[], aggregates: @[], annotations: @[], groupBy: @[],
    lockMode: lockNone))

proc selectFields*(query: QuerySet, fields: openArray[string]): QuerySet =
  ## Replace the projection while preserving filters and execution controls.
  result = query
  result.query.columns = @[]
  for field in fields:
    result.query.columns.add(field)

proc whereFilter*(query: QuerySet, value: QueryFilter): QuerySet =
  ## Add one bound predicate; values remain outside the SQL string.
  result = query
  result.query.filters = query.query.filters & @[value]

proc orderByField*(query: QuerySet, field: string,
                   descending = false): QuerySet =
  ## Add deterministic ordering to the builder.
  result = query
  result.query.orderBy = query.query.orderBy &
    @[QueryOrder(field: field, descending: descending)]

proc groupByFields*(query: QuerySet, fields: openArray[string]): QuerySet =
  ## Grouping is explicit so aggregate queries cannot accidentally group by a
  ## backend-specific implicit column set.
  result = query
  result.query.groupBy = @[]
  for field in fields:
    result.query.groupBy.add(field)

proc addAggregate*(query: QuerySet, function: QueryAggregateFunction,
                   field, alias: string): QuerySet =
  ## Add a typed aggregate expression with an explicit response column name.
  result = query
  result.query.aggregates = query.query.aggregates &
    @[QueryAggregate(function: function, field: field, alias: alias)]

proc annotateFields*(query: QuerySet, function: QueryAnnotationFunction,
                     leftField, rightField, alias: string): QuerySet =
  ## Keep annotation expressions in the query AST. Repositories resolve these
  ## logical fields through ModelMetadata before SQL compilation.
  result = query
  result.query.annotations = query.query.annotations &
    @[QueryAnnotation(leftField: leftField, rightField: rightField,
      function: function, alias: alias)]

proc lockRows*(query: QuerySet, mode: QueryLockMode): QuerySet =
  ## Typed locking intent keeps row-lock semantics reviewable and lets each
  ## backend reject unsupported behavior before a query reaches the driver.
  result = query
  result.query.lockMode = mode

proc paginate*(query: QuerySet, pagination: Pagination): QuerySet =
  ## Reuse the bounded pagination contract used by HTTP query components.
  result = query
  result.query = result.query.withPagination(pagination)

proc toSelectQuery*(query: QuerySet): SelectQuery = query.query

proc compile*(query: QuerySet,
              dialect = dialectSqlite): CompiledQuery =
  ## Keep compilation at the database boundary, where identifiers and values
  ## can be validated together with the selected SQL dialect.
  compileSelect(query.query, dialect)

proc compileSelect*(query: SelectQuery,
                    dialect = dialectSqlite): CompiledQuery =
  ## Compile intent and values separately so every driver can bind parameters.
  if query.table.len == 0 or (query.columns.len == 0 and
      query.aggregates.len == 0 and query.annotations.len == 0):
    raise newException(ValueError, "SELECT requires a table and projection")
  if query.limit < 0 or query.offset < 0:
    raise newException(ValueError, "Query limit and offset cannot be negative")
  result.sql = "SELECT "
  var selected: seq[string] = @[]
  for column in query.columns:
    selected.add(quoteIdentifier(column))
  for aggregate in query.aggregates:
    if aggregate.alias.len == 0:
      raise newException(ValueError, "Aggregate alias is required")
    let expression = if aggregate.function == aggregateCount and
        aggregate.field == "*": "*" else: quoteIdentifier(aggregate.field)
    selected.add(aggregateSql(aggregate.function) & "(" & expression & ") AS " &
      quoteIdentifier(aggregate.alias))
  for annotation in query.annotations:
    if annotation.leftField.len == 0 or annotation.rightField.len == 0:
      raise newException(ValueError, "Annotation fields are required")
    if annotation.alias.len == 0:
      raise newException(ValueError, "Annotation alias is required")
    selected.add(quoteIdentifier(annotation.leftField) &
      annotationSql(annotation.function) & quoteIdentifier(annotation.rightField) &
      " AS " & quoteIdentifier(annotation.alias))
  result.sql.add(selected.join(", "))
  result.sql.add(" FROM " & quoteIdentifier(query.table))
  var parameterIndex = 0
  for index, filter in query.filters:
    if filter.field.len == 0:
      raise newException(ValueError, "Filter field cannot be empty")
    result.sql.add(if index == 0: " WHERE " else: " AND ")
    if filter.operator == filterIn:
      if filter.value.kind != sqlList or filter.value.values.len == 0:
        raise newException(ValueError, "IN filter requires a non-empty typed list")
      result.sql.add(quoteIdentifier(filter.field) & " IN (")
      for itemIndex, item in filter.value.values:
        if item.kind == sqlList:
          raise newException(ValueError, "Nested IN lists are not supported")
        if itemIndex > 0:
          result.sql.add(", ")
        inc parameterIndex
        result.sql.add(if dialect == dialectPostgres: "$" & $parameterIndex else: "?")
        result.parameters.add(item)
      result.sql.add(")")
    else:
      result.sql.add(quoteIdentifier(filter.field) & operatorSql(filter.operator))
      if filter.operator notin {filterIsNull, filterIsNotNull}:
        inc parameterIndex
        result.sql.add(if dialect == dialectPostgres: "$" & $parameterIndex else: "?")
        result.parameters.add(filter.value)
  if query.groupBy.len > 0:
    var groups: seq[string] = @[]
    for field in query.groupBy:
      groups.add(quoteIdentifier(field))
    result.sql.add(" GROUP BY " & groups.join(", "))
  if query.orderBy.len > 0:
    var orders: seq[string] = @[]
    for order in query.orderBy:
      orders.add(quoteIdentifier(order.field) & (if order.descending: " DESC" else: " ASC"))
    result.sql.add(" ORDER BY " & orders.join(", "))
  if query.limit > 0:
    result.sql.add(" LIMIT " & $query.limit)
  if query.offset > 0:
      result.sql.add(" OFFSET " & $query.offset)
  if query.lockMode != lockNone:
    if dialect == dialectSqlite:
      raise newException(ValueError,
        "SQLite does not support row locking clauses")
    if query.aggregates.len > 0 or query.annotations.len > 0 or
        query.groupBy.len > 0:
      raise newException(ValueError,
        "Row locks cannot be applied to aggregate queries")
    result.sql.add(if query.lockMode == lockForUpdate:
      " FOR UPDATE" else: " FOR SHARE")

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
  ## Keep migration DDL metadata-driven so a generated schema preserves the
  ## repository's typed values and generated-key contract.
  proc fieldType(field: ModelField): string =
    case field.kind
    of modelInteger: "INTEGER"
    of modelFloat: "REAL"
    of modelBoolean: "BOOLEAN"
    of modelJson, modelFile: "TEXT"
    of modelDateTime, modelUuid, modelReference, modelString: "TEXT"
  proc columnDefinition(field: ModelField, includePrimaryKey = true): string =
    let columnName = if field.columnName.len > 0: field.columnName else: field.name
    result = quoteIdentifier(columnName) & " " & fieldType(field)
    if includePrimaryKey and field.primaryKey:
      result.add(" PRIMARY KEY")
      if dialect == dialectSqlite and field.kind == modelInteger:
        result.add(" AUTOINCREMENT")
    elif includePrimaryKey and not field.nullable:
      result.add(" NOT NULL")
    if includePrimaryKey and field.unique and not field.primaryKey:
      result.add(" UNIQUE")
  case operation.kind
  of migrationCreateTable:
    if operation.table.len == 0: raise newException(ValueError, "Table is required")
    "CREATE TABLE " & quoteIdentifier(operation.table) & " (" &
      columnDefinition(operation.field) & ")"
  of migrationAddColumn:
    "ALTER TABLE " & quoteIdentifier(operation.table) & " ADD COLUMN " &
      columnDefinition(operation.field, includePrimaryKey = false)
  of migrationCreateIndex:
    if operation.index.fields.len == 0: raise newException(ValueError, "Index needs fields")
    var fields: seq[string] = @[]
    for field in operation.index.fields: fields.add(quoteIdentifier(field))
    "CREATE " & (if operation.index.unique: "UNIQUE " else: "") & "INDEX " &
      quoteIdentifier(operation.index.name) & " ON " & quoteIdentifier(operation.table) &
      " (" & fields.join(", ") & ")"
  of migrationDropTable:
    "DROP TABLE " & quoteIdentifier(operation.table)
