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
  of sqlList:
    raise newException(ValueError, "List values cannot be mapped as row scalars")

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
  of sqlList:
    raise newException(ValueError, "List values cannot be mapped as row scalars")

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

proc listManyToManyRelated(repository: DatabaseRepository,
                           relation: ModelRelation,
                           target: ModelMetadata,
                           localValue: SqlValue,
                           query: RelationSelectQuery): seq[ResourceRow] =
  ## Compile a two-hop target-through-source join. The through table is part
  ## of relation metadata, while every value remains a bound SqlValue.
  if relation.throughTable.len == 0 or relation.throughLocalField.len == 0 or
      relation.throughForeignField.len == 0:
    raise newException(ValueError,
      "Many-to-many relation requires explicit through metadata")
  let local = repository.fieldFor(relation.localField)
  let foreign = target.field(relation.foreignField)
  if local.isNone or foreign.isNone:
    raise newException(ValueError, "Unknown many-to-many relation field")
  var normalized = RelationSelectQuery(table: target.tableName, alias: "target",
    columns: @[], joins: @[], filters: @[], orderBy: @[],
    limit: query.limit, offset: query.offset)
  if query.columns.len == 0:
    for field in target.fields:
      normalized.columns.add(field.columnName)
  else:
    for column in query.columns:
      let field = target.field(relationBaseField(column))
      if field.isNone:
        raise newException(ValueError,
          "Unknown many-to-many target field: " & column)
      normalized.columns.add(field.get().columnName)
  normalized.joins.add(RelationJoin(kind: relationInnerJoin,
    table: relation.throughTable, alias: "through", localTable: "target",
    localField: foreign.get().columnName,
    foreignField: relation.throughForeignField))
  normalized.filters = query.filters
  normalized.filters.add(QueryFilter(field: "through." &
    relation.throughLocalField, operator: filterEqual, value: localValue))
  normalized.orderBy = query.orderBy
  let compiled = compileRelationSelect(normalized, repository.adapter.dialect)
  let targetRepository = newDatabaseRepository(target, repository.adapter)
  for values in repository.adapter.execute(compiled):
    result.add(targetRepository.rowFromValues(values))

proc relationValueKey(value: SqlValue): string =
  ## A typed key prevents an integer `1` and text `1` from being merged while
  ## grouping rows returned by a batched relation query. The same key format is
  ## used for through-table values and mapped JSON model values.
  $value.kind & ":" & scalarText(value)

proc relationFieldKey(value: SqlValue, field: ModelField): string =
  ## Drivers may return a numeric foreign key as text while model mapping
  ## exposes it as JSON integer. Normalize both sides using metadata before
  ## grouping, otherwise a valid SQLite relation would disappear silently.
  case field.kind
  of modelInteger:
    try: "sqlInteger:" & $parseInt(scalarText(value))
    except ValueError: relationValueKey(value)
  of modelFloat:
    try: "sqlFloat:" & $parseFloat(scalarText(value))
    except ValueError: relationValueKey(value)
  of modelBoolean:
    "sqlBoolean:" & $scalarText(value).toLowerAscii()
  else:
    "sqlText:" & scalarText(value)

proc relationJsonKey(value: JsonNode, field: ModelField): string =
  ## Convert a model row's JSON value back to the metadata-normalized key.
  relationFieldKey(sqlValue(value), field)

proc listManyToManyRelatedBatched(repository: DatabaseRepository,
                                  relation: ModelRelation,
                                  target: ModelMetadata,
                                  query: RelationSelectQuery,
                                  baseRows: seq[ResourceRow]): Table[string,
                                    seq[ResourceRow]] =
  ## Batch a parent page's many-to-many eager load as two bounded queries:
  ## through(local, target) followed by target IN (target keys). This avoids
  ## one join query per parent while keeping projection and target filtering in
  ## the target repository. Pagination belongs to the parent page; applying a
  ## single global child LIMIT would otherwise drop relations unpredictably.
  if relation.throughTable.len == 0 or relation.throughLocalField.len == 0 or
      relation.throughForeignField.len == 0:
    raise newException(ValueError,
      "Many-to-many relation requires explicit through metadata")
  let local = repository.fieldFor(relation.localField)
  let targetForeign = target.field(relation.foreignField)
  if local.isNone or targetForeign.isNone:
    raise newException(ValueError, "Unknown many-to-many relation field")

  var localValues: seq[SqlValue] = @[]
  var seenLocal: Table[string, bool] = initTable[string, bool]()
  let localName = local.get().name
  for row in baseRows:
    if row.hasKey(localName) and row[localName].kind != JNull:
      let value = sqlValue(row[localName])
      let key = relationJsonKey(row[localName], local.get())
      if not seenLocal.hasKey(key):
        seenLocal[key] = true
        localValues.add(value)

  var grouped: Table[string, seq[ResourceRow]] = initTable[string, seq[ResourceRow]]()
  if localValues.len == 0:
    return grouped

  ## The through projection is deliberately kept separate from target model
  ## mapping; mapping a through column as a target field would shift every
  ## projected value and violate the repository's metadata ordering contract.
  let throughQuery = SelectQuery(table: relation.throughTable,
    columns: @[relation.throughLocalField, relation.throughForeignField],
    filters: @[QueryFilter(field: relation.throughLocalField,
      operator: filterIn, value: listValue(localValues))])
  let throughRows = repository.adapter.execute(
    compileSelect(throughQuery, repository.adapter.dialect))
  var targetValues: seq[SqlValue] = @[]
  var seenTargets: Table[string, bool] = initTable[string, bool]()
  var targetParents: Table[string, seq[string]] = initTable[string, seq[string]]()
  for values in throughRows:
    if values.len < 2 or values[0].kind == sqlNull or values[1].kind == sqlNull:
      continue
    let parentKey = relationFieldKey(values[0], local.get())
    let targetKey = relationFieldKey(values[1], targetForeign.get())
    if not targetParents.hasKey(targetKey):
      targetParents[targetKey] = @[]
    if parentKey notin targetParents[targetKey]:
      targetParents[targetKey].add(parentKey)
    if not seenTargets.hasKey(targetKey):
      seenTargets[targetKey] = true
      targetValues.add(values[1])

  if targetValues.len == 0:
    return grouped
  let targetRepository = newDatabaseRepository(target, repository.adapter)
  var targetQuery = SelectQuery(columns: @[], filters: query.filters,
    orderBy: @[])
  for column in query.columns:
    targetQuery.columns.add(relationBaseField(column))
  var addedForeign = false
  if targetQuery.columns.len > 0 and relation.foreignField notin targetQuery.columns:
    targetQuery.columns.add(relation.foreignField)
    addedForeign = true
  targetQuery.filters.add(QueryFilter(field: relation.foreignField,
    operator: filterIn, value: listValue(targetValues)))
  for order in query.orderBy:
    targetQuery.orderBy.add(QueryOrder(field: relationBaseField(order.field),
      descending: order.descending))
  for targetRow in targetRepository.list(targetQuery):
    if not targetRow.hasKey(targetForeign.get().name):
      continue
    let targetKey = relationJsonKey(targetRow[targetForeign.get().name],
      targetForeign.get())
    if not targetParents.hasKey(targetKey):
      continue
    var projected = targetRow
    if addedForeign:
      projected.del(targetForeign.get().name)
    for parentKey in targetParents[targetKey]:
      if not grouped.hasKey(parentKey):
        grouped[parentKey] = @[]
      grouped[parentKey].add(projected)
  grouped

proc listRelationWithRelatedBatched*(repository: DatabaseRepository,
                                     relation: ModelRelation,
                                     target: ModelMetadata,
                                     query = RelationSelectQuery()): seq[ResourceRow] =
  ## Execute one target query for all one-to-many parent keys on the selected
  ## base page. Pagination belongs to the parent query; each returned parent
  ## still receives its complete child collection, avoiding N+1 queries without
  ## silently applying one global child LIMIT to every parent.
  if relation.kind != relationOneToMany:
    raise newException(ValueError,
      "Batched relation loading currently supports one-to-many relations")
  if relation.localField.len == 0 or relation.foreignField.len == 0:
    raise newException(ValueError, "Relation fields are required")
  if target.tableName.len == 0:
    raise newException(ValueError, "Relation target table is required")
  if query.joins.len > 0:
    raise newException(ValueError,
      "Batched eager loading accepts one relation without additional joins")
  let local = repository.fieldFor(relation.localField)
  let foreign = target.field(relation.foreignField)
  if local.isNone or foreign.isNone:
    raise newException(ValueError, "Unknown relation field")

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
  let foreignName = foreign.get().name
  var localValues: seq[SqlValue] = @[]
  var seen: Table[string, bool] = initTable[string, bool]()
  for row in baseRows:
    if row.hasKey(localName) and row[localName].kind != JNull:
      let value = sqlValue(row[localName])
      let key = relationJsonKey(row[localName], local.get())
      if not seen.hasKey(key):
        seen[key] = true
        localValues.add(value)

  var grouped: Table[string, seq[ResourceRow]] = initTable[string, seq[ResourceRow]]()
  if localValues.len > 0:
    var relatedQuery = SelectQuery(columns: query.columns, filters: query.filters,
      orderBy: query.orderBy)
    var addedForeign = false
    if relatedQuery.columns.len > 0 and relation.foreignField notin
        relatedQuery.columns:
      relatedQuery.columns.add(relation.foreignField)
      addedForeign = true
    relatedQuery.filters.add(QueryFilter(field: relation.foreignField,
      operator: filterIn, value: listValue(localValues)))
    for related in targetRepository.list(relatedQuery):
      if not related.hasKey(foreignName):
        continue
      let key = relationJsonKey(related[foreignName], foreign.get())
      if not grouped.hasKey(key):
        grouped[key] = @[]
      var projected = related
      if addedForeign:
        projected.del(foreignName)
      grouped[key].add(projected)

  for originalRow in baseRows:
    var baseRow = originalRow
    var nested = newJArray()
    if baseRow.hasKey(localName) and baseRow[localName].kind != JNull:
      let key = relationJsonKey(baseRow[localName], local.get())
      if grouped.hasKey(key):
        for related in grouped[key]:
          nested.add(relationRowJson(related))
    baseRow[relation.name] = nested
    result.add(baseRow)

proc listRelationWithRelated*(repository: DatabaseRepository,
                              relation: ModelRelation,
                              target: ModelMetadata,
                              query = RelationSelectQuery()): seq[ResourceRow] =
  ## Load one relation as nested JSON without duplicating base rows. This is
  ## intentionally a separate API from listRelation: the latter is a stable
  ## join/base-row contract, while this method owns eager DTO assembly.
  if relation.kind == relationOneToMany and query.joins.len == 0:
    return repository.listRelationWithRelatedBatched(relation, target, query)
  if relation.kind == relationManyToMany and query.joins.len == 0:
    ## The base page is selected once, then all through rows and target rows
    ## for that page are loaded in bounded batches and grouped in memory.
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
    let grouped = repository.listManyToManyRelatedBatched(relation, target,
      query, baseRows)
    let local = repository.fieldFor(relation.localField)
    if local.isNone:
      raise newException(ValueError,
        "Unknown many-to-many local relation field")
    let localName = local.get().name
    for originalRow in baseRows:
      var baseRow = originalRow
      var nested = newJArray()
      if baseRow.hasKey(localName) and baseRow[localName].kind != JNull:
        let key = relationJsonKey(baseRow[localName], local.get())
        if grouped.hasKey(key):
          for related in grouped[key]:
            nested.add(relationRowJson(related))
      baseRow[relation.name] = nested
      result.add(baseRow)
    return result
  if relation.kind == relationManyToMany and
      (relation.throughTable.len == 0 or relation.throughLocalField.len == 0 or
       relation.throughForeignField.len == 0):
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
      if relation.kind == relationManyToMany:
        relatedRows = repository.listManyToManyRelated(relation, target,
          sqlValue(baseRow[localName]), query)
      else:
        let relatedQuery = SelectQuery(filters: @[
          QueryFilter(field: relation.foreignField, operator: filterEqual,
            value: sqlValue(baseRow[localName]))])
        relatedRows = targetRepository.list(relatedQuery)
    if relation.kind in {relationOneToMany, relationManyToMany}:
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
  if relation.kind == relationManyToMany and
      (relation.throughTable.len == 0 or relation.throughLocalField.len == 0 or
       relation.throughForeignField.len == 0):
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
  if loader.relation.kind == relationManyToMany:
    var relationQuery = RelationSelectQuery(columns: @[], joins: @[],
      filters: @[], orderBy: @[], limit: loader.query.limit,
      offset: loader.query.offset)
    relationQuery.columns = loader.query.columns
    relationQuery.filters = loader.query.filters
    relationQuery.orderBy = loader.query.orderBy
    return loader.repository.listManyToManyRelated(loader.relation,
      loader.target, localValue, relationQuery)
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
