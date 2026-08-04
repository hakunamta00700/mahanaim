## Metadata-driven database repository.
##
## The repository translates ResourceRow values into the backend-neutral
## DatabaseAdapter contract. It intentionally does not own HTTP behavior;
## resources.nim can attach this store to the existing CRUD route convention
## once request/session wiring is ready.

import std/[json, options, strutils, tables]
import ./database
import ./models
import ./resources

type
  DatabaseRepository* = ref object
    metadata*: ModelMetadata
    adapter*: DatabaseAdapter
    idField*: string

  DatabaseRepositoryResourceStore* = ref object of ResourceStore
    ## Adapt repository persistence to the existing CRUD route contract. The
    ## adapter owns no HTTP behavior; resources.nim remains responsible for
    ## validation, response status, and route registration.
    repository*: DatabaseRepository

  RelationLoader* = ref object of RootObj
    ## A deferred relation operation; rows are fetched only by an explicit
    ## `load` call so the caller can choose lazy or eager behavior.

  DatabaseRelationLoader* = ref object of RelationLoader
    repository*: DatabaseRepository
    relation*: ModelRelation
    target*: ModelMetadata
    query*: SelectQuery

method load*(loader: RelationLoader,
             localValue: SqlValue): seq[ResourceRow] {.base, gcsafe.} =
  discard loader
  discard localValue
  raise newException(ValueError, "Relation loader does not implement load")

proc newDatabaseRepository*(metadata: ModelMetadata,
                            adapter: DatabaseAdapter): DatabaseRepository =
  ## Keep repository construction explicit so a connection cannot be hidden in
  ## global state or accidentally shared across request lifecycles.
  if adapter.isNil:
    raise newException(ValueError, "Database repository requires an adapter")
  new(result)
  result.metadata = metadata
  result.adapter = adapter
  result.idField = "id"
  for field in metadata.fields:
    if field.primaryKey:
      result.idField = field.name
      break

## Forward declarations keep the ResourceStore adapter near its type while
## allowing the repository implementation to remain grouped by operation.
proc list*(repository: DatabaseRepository,
           query = SelectQuery()): seq[ResourceRow] {.gcsafe.}
proc listWithTotal*(repository: DatabaseRepository,
                    query = SelectQuery()): ResourceListResult {.gcsafe.}
proc find*(repository: DatabaseRepository, id: string): Option[ResourceRow] {.gcsafe.}
proc create*(repository: DatabaseRepository, row: ResourceRow): ResourceRow {.gcsafe.}
proc update*(repository: DatabaseRepository, id: string,
             row: ResourceRow): Option[ResourceRow] {.gcsafe.}
proc delete*(repository: DatabaseRepository, id: string): bool {.gcsafe.}

proc newDatabaseRepositoryResourceStore*(repository: DatabaseRepository):
    DatabaseRepositoryResourceStore =
  ## Keep the repository explicit so request/session ownership can be added by
  ## an application integration without hiding a connection in the store.
  if repository.isNil:
    raise newException(ValueError, "Database repository store requires a repository")
  DatabaseRepositoryResourceStore(repository: repository)

method list*(store: DatabaseRepositoryResourceStore,
             query: SelectQuery): seq[ResourceRow] {.gcsafe.} =
  store.repository.list(query)

method listWithTotal*(store: DatabaseRepositoryResourceStore,
                      query: SelectQuery): ResourceListResult {.gcsafe.} =
  ## Database-backed resources use a COUNT aggregate instead of materializing
  ## every matching row merely to produce pagination metadata.
  store.repository.listWithTotal(query)

method find*(store: DatabaseRepositoryResourceStore,
             id: string): Option[ResourceRow] {.gcsafe.} =
  store.repository.find(id)

method create*(store: DatabaseRepositoryResourceStore,
               row: ResourceRow): ResourceRow {.gcsafe.} =
  store.repository.create(row)

method update*(store: DatabaseRepositoryResourceStore, id: string,
               row: ResourceRow): Option[ResourceRow] {.gcsafe.} =
  store.repository.update(id, row)

method delete*(store: DatabaseRepositoryResourceStore,
               id: string): bool {.gcsafe.} =
  store.repository.delete(id)

proc fieldFor(repository: DatabaseRepository, name: string): Option[ModelField] =
  for field in repository.metadata.fields:
    if field.name == name or field.columnName == name or field.jsonName == name:
      return some(field)
  none(ModelField)

proc identifier(value: string): string =
  ## Repository-generated identifiers are still validated at this boundary;
  ## values from a request are never treated as raw SQL fragments.
  if value.len == 0:
    raise newException(ValueError, "Repository identifier cannot be empty")
  for character in value:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      raise newException(ValueError, "Unsafe repository identifier: " & value)
  "\"" & value & "\""

proc sqlValue(value: JsonNode): SqlValue =
  ## JSON is the transport type at the CRUD boundary; nested values are kept
  ## as canonical JSON text until a typed custom adapter is introduced.
  case value.kind
  of JNull: nullValue()
  of JString: textValue(value.getStr())
  of JInt: integerValue(value.getInt())
  of JFloat: floatValue(value.getFloat())
  of JBool: booleanValue(value.getBool())
  of JObject, JArray: textValue($value)

proc scalarText(value: SqlValue): string =
  ## Drivers currently expose a text protocol at the neutral boundary, but
  ## this conversion also keeps repository mapping correct for typed adapters.
  case value.kind
  of sqlNull: ""
  of sqlText: value.text
  of sqlInteger: $value.integer
  of sqlFloat: $value.floating
  of sqlBoolean:
    if value.boolean: "true" else: "false"

proc jsonValue(field: ModelField, value: SqlValue): JsonNode =
  if value.kind == sqlNull:
    return newJNull()
  let text = scalarText(value)
  case field.kind
  of modelInteger:
    try: newJInt(parseInt(text))
    except ValueError: newJString(text)
  of modelFloat:
    try: newJFloat(parseFloat(text))
    except ValueError: newJString(text)
  of modelBoolean:
    newJBool(text.toLowerAscii() in ["1", "true", "t", "yes"])
  of modelJson:
    try: parseJson(text)
    except CatchableError: newJString(text)
  else: newJString(text)

proc jsonValue(value: SqlValue): JsonNode =
  ## Annotation results have no ModelField, so preserve the neutral scalar
  ## kind directly instead of guessing from metadata or returning text.
  case value.kind
  of sqlNull: newJNull()
  of sqlText: newJString(value.text)
  of sqlInteger: newJInt(value.integer)
  of sqlFloat: newJFloat(value.floating)
  of sqlBoolean: newJBool(value.boolean)

proc columns(repository: DatabaseRepository): seq[string] =
  for field in repository.metadata.fields:
    result.add(field.columnName)

proc rowFromValues(repository: DatabaseRepository, query: SelectQuery,
                   values: seq[SqlValue]): ResourceRow =
  ## Map by the actual projection. This supports both partial selections and
  ## computed annotation aliases without coupling response order to metadata
  ## declaration order.
  var valueIndex = 0
  for column in query.columns:
    if valueIndex >= values.len:
      break
    let field = repository.fieldFor(column)
    if field.isSome:
      result[field.get().name] = jsonValue(field.get(), values[valueIndex])
    inc valueIndex
  for annotation in query.annotations:
    if valueIndex >= values.len:
      break
    ## SQLite may expose computed numeric columns through its text protocol.
    ## Reuse the left operand's metadata so an integer/float annotation keeps
    ## the same JSON type as the model field that determines its arithmetic.
    let field = repository.fieldFor(annotation.leftField)
    result[annotation.alias] = if field.isSome:
      jsonValue(field.get(), values[valueIndex])
    else:
      jsonValue(values[valueIndex])
    inc valueIndex

proc rowFromValues(repository: DatabaseRepository,
                   values: seq[SqlValue]): ResourceRow =
  ## RelationSelectQuery results predate projected QuerySet rows and use the
  ## repository's declared field order. Keep this adapter overload isolated so
  ## relation loading remains compatible while normal lists use projection
  ## aware mapping above.
  for index, field in repository.metadata.fields:
    if index < values.len:
      result[field.name] = jsonValue(field, values[index])

proc normalizeQuery(repository: DatabaseRepository,
                    query: SelectQuery): SelectQuery =
  var normalized = query
  normalized.table = repository.metadata.tableName
  if normalized.columns.len == 0 and normalized.aggregates.len == 0:
    normalized.columns = repository.columns()
  else:
    for index, name in normalized.columns:
      let field = repository.fieldFor(name)
      if field.isNone:
        raise newException(ValueError, "Unknown repository field: " & name)
      normalized.columns[index] = field.get().columnName
  for filter in normalized.filters.mitems:
    let field = repository.fieldFor(filter.field)
    if field.isNone:
      raise newException(ValueError, "Unknown repository filter: " & filter.field)
    filter.field = field.get().columnName
  for order in normalized.orderBy.mitems:
    let field = repository.fieldFor(order.field)
    if field.isNone:
      raise newException(ValueError, "Unknown repository order: " & order.field)
    order.field = field.get().columnName
  for aggregate in normalized.aggregates.mitems:
    if aggregate.field == "*":
      if aggregate.function != aggregateCount:
        raise newException(ValueError, "Only COUNT supports wildcard aggregate fields")
    else:
      let field = repository.fieldFor(aggregate.field)
      if field.isNone:
        raise newException(ValueError, "Unknown repository aggregate field: " &
          aggregate.field)
      aggregate.field = field.get().columnName
  for annotation in normalized.annotations.mitems:
    let left = repository.fieldFor(annotation.leftField)
    let right = repository.fieldFor(annotation.rightField)
    if left.isNone or right.isNone:
      raise newException(ValueError, "Unknown repository annotation field")
    annotation.leftField = left.get().columnName
    annotation.rightField = right.get().columnName
  for group in normalized.groupBy.mitems:
    let field = repository.fieldFor(group)
    if field.isNone:
      raise newException(ValueError, "Unknown repository group field: " & group)
    group = field.get().columnName
  normalized

proc selectQuery(repository: DatabaseRepository,
                 query: SelectQuery): CompiledQuery =
  compileSelect(repository.normalizeQuery(query), repository.adapter.dialect)

proc list*(repository: DatabaseRepository,
           query = SelectQuery()): seq[ResourceRow] {.gcsafe.} =
  ## List uses the shared compiler, including pagination and bound filters.
  if query.aggregates.len > 0 or query.groupBy.len > 0:
    raise newException(ValueError,
      "Aggregate queries must use DatabaseRepository.aggregate")
  let normalized = repository.normalizeQuery(query)
  let compiled = compileSelect(normalized, repository.adapter.dialect)
  for values in repository.adapter.execute(compiled):
    result.add(repository.rowFromValues(normalized, values))

proc listWithTotal*(repository: DatabaseRepository,
                    query = SelectQuery()): ResourceListResult {.gcsafe.} =
  ## Count and page use the same normalized filters, guaranteeing that total
  ## metadata describes the requested query rather than the whole table.
  if query.aggregates.len > 0 or query.groupBy.len > 0:
    raise newException(ValueError,
      "Aggregate queries must use DatabaseRepository.aggregate")
  let normalized = repository.normalizeQuery(query)
  var countQuery = normalized
  countQuery.columns = @[]
  countQuery.orderBy = @[]
  countQuery.limit = 0
  countQuery.offset = 0
  countQuery.aggregates = @[QueryAggregate(function: aggregateCount,
    field: "*", alias: "total")]
  let countRows = repository.adapter.execute(
    compileSelect(countQuery, repository.adapter.dialect))
  if countRows.len > 0 and countRows[0].len > 0:
    let countValue = countRows[0][0]
    result.total = case countValue.kind
      of sqlInteger: countValue.integer
      of sqlText:
        try: parseInt(countValue.text).int64
        except ValueError: 0
      else: 0
  result.rows = repository.list(query)

proc aggregateJson(function: QueryAggregateFunction,
                   field: Option[ModelField], value: SqlValue): JsonNode =
  ## Restore useful JSON scalar types from the driver's text result protocol.
  if value.kind == sqlNull:
    return newJNull()
  let text = scalarText(value)
  case function
  of aggregateCount:
    try: newJInt(parseInt(text))
    except ValueError: newJString(text)
  of aggregateAverage:
    try: newJFloat(parseFloat(text))
    except ValueError: newJString(text)
  of aggregateSum, aggregateMinimum, aggregateMaximum:
    if field.isSome:
      jsonValue(field.get(), value)
    else:
      newJString(text)

proc aggregateRow(repository: DatabaseRepository, query: SelectQuery,
                  values: seq[SqlValue]): ResourceRow =
  ## Map selected group fields and aggregate aliases independently of model
  ## serialization; aggregate aliases are not model fields by design.
  var valueIndex = 0
  for column in query.columns:
    if valueIndex >= values.len: break
    let field = repository.fieldFor(column)
    if field.isSome:
      result[field.get().name] = jsonValue(field.get(), values[valueIndex])
    inc valueIndex
  for aggregate in query.aggregates:
    if valueIndex >= values.len: break
    let field = if aggregate.field == "*": none(ModelField) else:
      repository.fieldFor(aggregate.field)
    result[aggregate.alias] = aggregateJson(aggregate.function, field,
      values[valueIndex])
    inc valueIndex

proc aggregate*(repository: DatabaseRepository,
                query: QuerySet): seq[ResourceRow] {.gcsafe.} =
  ## Execute a QuerySet aggregate and expose stable JSON rows for API/service
  ## layers. Ordinary CRUD list remains intentionally model-shaped.
  let requested = query.toSelectQuery()
  if requested.aggregates.len == 0:
    raise newException(ValueError, "Aggregate query requires an aggregate")
  let normalized = repository.normalizeQuery(requested)
  let compiled = compileSelect(normalized, repository.adapter.dialect)
  for values in repository.adapter.execute(compiled):
    result.add(repository.aggregateRow(normalized, values))

proc listRelation*(repository: DatabaseRepository,
                   relation: ModelRelation,
                   target: ModelMetadata,
                   query = RelationSelectQuery()): seq[ResourceRow] =
  ## Execute one-hop relation loading while returning only the base model.
  ## Target projection can be added by a separate DTO loader without changing
  ## this repository's stable base-row contract.
  if relation.localField.len == 0 or relation.foreignField.len == 0:
    raise newException(ValueError, "Relation fields are required")
  if target.tableName.len == 0:
    raise newException(ValueError, "Relation target table is required")
  let local = repository.fieldFor(relation.localField)
  if local.isNone:
    raise newException(ValueError,
      "Unknown relation local field: " & relation.localField)
  let foreign = target.field(relation.foreignField)
  if foreign.isNone:
    raise newException(ValueError,
      "Unknown relation target field: " & relation.foreignField)
  var normalized = query
  normalized.table = repository.metadata.tableName
  normalized.alias = "base"
  if normalized.columns.len == 0:
    for field in repository.metadata.fields:
      normalized.columns.add("base." & field.columnName)
  normalized.joins.insert(RelationJoin(kind: relationInnerJoin,
    table: target.tableName,
    alias: relation.name,
    localTable: "base",
    localField: local.get().columnName,
    foreignField: foreign.get().columnName), 0)
  let compiled = compileRelationSelect(normalized, repository.adapter.dialect)
  for values in repository.adapter.execute(compiled):
    result.add(repository.rowFromValues(values))

proc relationBaseField(name: string): string =
  ## Relation queries may qualify base fields for join compilation. Eager
  ## loading executes the base and related projections separately, so the
  ## repository validation boundary receives the unqualified model field.
  if name.startsWith("base."):
    return name[5 .. ^1]
  name

proc relationRowJson(row: ResourceRow): JsonNode =
  ## Nested relation output is assembled at the JSON boundary, while each
  ## table row remains mapped by its own repository metadata.
  result = newJObject()
  for name, value in row:
    result[name] = value

proc listRelationWithRelated*(repository: DatabaseRepository,
                              relation: ModelRelation,
                              target: ModelMetadata,
                              query = RelationSelectQuery()): seq[ResourceRow] =
  ## Load one relation as nested JSON without duplicating base rows. This is
  ## intentionally a separate API from listRelation: the latter is a stable
  ## join/base-row contract, while this method owns eager DTO assembly.
  if relation.kind == relationManyToMany:
    raise newException(ValueError,
      "Many-to-many eager loading requires an explicit through relation")
  if relation.localField.len == 0 or relation.foreignField.len == 0:
    raise newException(ValueError, "Relation fields are required")
  if target.tableName.len == 0:
    raise newException(ValueError, "Relation target table is required")
  if query.joins.len > 0:
    raise newException(ValueError,
      "Eager relation loading accepts one relation without additional joins")
  let local = repository.fieldFor(relation.localField)
  if local.isNone:
    raise newException(ValueError,
      "Unknown relation local field: " & relation.localField)
  if target.field(relation.foreignField).isNone:
    raise newException(ValueError,
      "Unknown relation target field: " & relation.foreignField)

  var baseQuery = SelectQuery(limit: query.limit, offset: query.offset)
  for column in query.columns:
    baseQuery.columns.add(relationBaseField(column))
  for order in query.orderBy:
    baseQuery.orderBy.add(QueryOrder(field: relationBaseField(order.field),
      descending: order.descending))
  baseQuery.filters = query.filters
  for filter in baseQuery.filters.mitems:
    filter.field = relationBaseField(filter.field)
  let baseRows = repository.list(baseQuery)
  let targetRepository = newDatabaseRepository(target, repository.adapter)
  let localName = local.get().name
  for originalRow in baseRows:
    var baseRow = originalRow
    var relatedRows: seq[ResourceRow] = @[]
    if baseRow.hasKey(localName) and baseRow[localName].kind != JNull:
      let relatedQuery = SelectQuery(filters: @[
        QueryFilter(field: relation.foreignField, operator: filterEqual,
          value: sqlValue(baseRow[localName]))])
      relatedRows = targetRepository.list(relatedQuery)
    if relation.kind == relationOneToMany:
      var nested = newJArray()
      for relatedRow in relatedRows:
        nested.add(relationRowJson(relatedRow))
      baseRow[relation.name] = nested
    else:
      if relatedRows.len > 0:
        baseRow[relation.name] = relationRowJson(relatedRows[0])
      else:
        baseRow[relation.name] = newJNull()
    result.add(baseRow)

proc newLazyRelationLoader*(repository: DatabaseRepository,
                            relation: ModelRelation,
                            target: ModelMetadata,
                            query = SelectQuery()): DatabaseRelationLoader =
  ## Construct the deferred boundary without touching the database. This
  ## keeps N+1 behavior visible at the call site and preserves one explicit
  ## responsibility for query execution in the loader.
  if repository.isNil:
    raise newException(ValueError, "Lazy relation loader requires a repository")
  if relation.kind == relationManyToMany:
    raise newException(ValueError,
      "Many-to-many lazy loading requires an explicit through relation")
  if relation.localField.len == 0 or relation.foreignField.len == 0:
    raise newException(ValueError, "Relation fields are required")
  if repository.fieldFor(relation.localField).isNone or
      target.field(relation.foreignField).isNone:
    raise newException(ValueError, "Unknown lazy relation field")
  DatabaseRelationLoader(repository: repository, relation: relation,
    target: target, query: query)

method load*(loader: DatabaseRelationLoader,
             localValue: SqlValue): seq[ResourceRow] {.gcsafe.} =
  ## Execute only at the first explicit load call and reuse ordinary target
  ## repository mapping for typed fields and selected projections.
  if loader.isNil:
    raise newException(ValueError, "Relation loader is nil")
  let targetRepository = newDatabaseRepository(loader.target,
    loader.repository.adapter)
  var query = loader.query
  query.filters.add(QueryFilter(field: loader.relation.foreignField,
    operator: filterEqual, value: localValue))
  targetRepository.list(query)

proc idFilter(repository: DatabaseRepository, id: string): QueryFilter =
  let field = repository.fieldFor(repository.idField)
  if field.isNone:
    raise newException(ValueError, "Repository primary key field is missing")
  var value = textValue(id)
  if field.get().kind == modelInteger:
    try: value = integerValue(parseInt(id).int64)
    except ValueError: raise newException(ValueError, "Invalid integer repository id")
  QueryFilter(field: repository.idField, operator: filterEqual, value: value)

proc find*(repository: DatabaseRepository, id: string): Option[ResourceRow] {.gcsafe.} =
  var query = SelectQuery(filters: @[repository.idFilter(id)], limit: 1)
  let rows = repository.list(query)
  if rows.len > 0: some(rows[0]) else: none(ResourceRow)

proc rowId(repository: DatabaseRepository, row: ResourceRow): Option[JsonNode] =
  if row.hasKey(repository.idField): some(row[repository.idField])
  else: none(JsonNode)

proc create*(repository: DatabaseRepository, row: ResourceRow): ResourceRow {.gcsafe.} =
  ## Insert fields in metadata order for deterministic SQL and parameter order.
  var names: seq[string] = @[]
  var values: seq[SqlValue] = @[]
  for field in repository.metadata.fields:
    if row.hasKey(field.name):
      names.add(field.columnName)
      values.add(sqlValue(row[field.name]))
  if names.len == 0:
    raise newException(ValueError, "Repository create requires at least one field")
  var placeholders: seq[string] = @[]
  for index in 0 ..< values.len:
    placeholders.add(if repository.adapter.dialect == dialectPostgres:
      "$" & $(index + 1) else: "?")
  var sql = "INSERT INTO " & identifier(repository.metadata.tableName) & " ("
  var quoted: seq[string] = @[]
  for name in names: quoted.add(identifier(name))
  sql.add(quoted.join(", ") & ") VALUES (" & placeholders.join(", ") & ")")
  ## PostgreSQL can return generated columns in the same command. SQLite's
  ## db_connector versions vary in DML RETURNING support, so its adapter uses
  ## the native last-insert-rowid query below instead of depending on driver
  ## cursor behavior.
  var generatedKey = false
  for field in repository.metadata.fields:
    if field.primaryKey and not row.hasKey(field.name):
      generatedKey = true
      break
  if generatedKey and repository.adapter.dialect == dialectPostgres:
    var returnedColumns: seq[string] = @[]
    for field in repository.metadata.fields:
      returnedColumns.add(identifier(field.columnName))
    sql.add(" RETURNING " & returnedColumns.join(", "))
  let inserted = repository.adapter.execute(CompiledQuery(sql: sql, parameters: values))
  if generatedKey and inserted.len > 0:
    return repository.rowFromValues(inserted[0])
  if generatedKey and repository.adapter.dialect == dialectSqlite:
    let idRows = repository.adapter.execute(CompiledQuery(
      sql: "SELECT last_insert_rowid()", parameters: @[]))
    if idRows.len > 0 and idRows[0].len > 0:
      let found = repository.find(idRows[0][0].text)
      if found.isSome:
        return found.get()
  let id = repository.rowId(row)
  if id.isSome:
    let found = repository.find($id.get())
    if found.isSome: return found.get()
  row

proc update*(repository: DatabaseRepository, id: string,
             row: ResourceRow): Option[ResourceRow] {.gcsafe.} =
  if repository.find(id).isNone:
    return none(ResourceRow)
  var assignments: seq[string] = @[]
  var values: seq[SqlValue] = @[]
  for field in repository.metadata.fields:
    if field.name != repository.idField and row.hasKey(field.name):
      assignments.add(identifier(field.columnName) & " = " &
        (if repository.adapter.dialect == dialectPostgres:
          "$" & $(values.len + 1) else: "?"))
      values.add(sqlValue(row[field.name]))
  if assignments.len == 0:
    return repository.find(id)
  let idParameter = repository.idFilter(id).value
  values.add(idParameter)
  let idPlaceholder = if repository.adapter.dialect == dialectPostgres:
    "$" & $values.len else: "?"
  let sql = "UPDATE " & identifier(repository.metadata.tableName) & " SET " &
    assignments.join(", ") & " WHERE " & identifier(
      repository.fieldFor(repository.idField).get().columnName) & " = " & idPlaceholder
  discard repository.adapter.execute(CompiledQuery(sql: sql, parameters: values))
  repository.find(id)

proc delete*(repository: DatabaseRepository, id: string): bool {.gcsafe.} =
  if repository.find(id).isNone:
    return false
  let field = repository.fieldFor(repository.idField).get()
  let placeholder = if repository.adapter.dialect == dialectPostgres: "$1" else: "?"
  discard repository.adapter.execute(CompiledQuery(
    sql: "DELETE FROM " & identifier(repository.metadata.tableName) &
      " WHERE " & identifier(field.columnName) & " = " & placeholder,
    parameters: @[repository.idFilter(id).value]))
  true
