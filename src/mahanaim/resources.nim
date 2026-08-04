## Metadata-driven CRUD resource convention.
##
## `ResourceStore` is the persistence boundary. The in-memory implementation is
## a deterministic reference adapter for tests; SQLite/PostgreSQL adapters can
## implement the same methods without changing route, validation, or response
## behavior.

import std/[asyncdispatch, httpcore, json, options, strutils, tables]
import ./application
import ./core
import ./database
import ./models
import ./query_components
import ./serialization
import ./validation

type
  ResourceRow* = Table[string, JsonNode]

  ResourceListResult* = object
    ## A list page keeps total metadata separate from row serialization so
    ## stores can calculate it with an efficient COUNT query when available.
    rows*: seq[ResourceRow]
    total*: int64

  ResourceStore* = ref object of RootObj
    ## Persistence adapters own query execution and transaction details.

  InMemoryResourceStore* = ref object of ResourceStore
    metadata*: ModelMetadata
    rows*: seq[ResourceRow]
    nextId*: int64
    idField*: string

  CrudResource* = ref object
    ## Route behavior is shared while storage remains replaceable.
    metadata*: ModelMetadata
    store*: ResourceStore
    responsePolicy*: SerializationPolicy
    ## Cursor signing is explicit per resource so secrets do not leak into a
    ## global query parser or get guessed from application configuration.
    cursorSecret*: string
    cursorTtlSeconds*: int64

method list*(store: ResourceStore,
             query: SelectQuery): seq[ResourceRow] {.base, gcsafe.} =
  discard store
  discard query
  raise newException(ValueError, "Resource store does not implement list")

method listWithTotal*(store: ResourceStore,
                      query: SelectQuery): ResourceListResult {.base, gcsafe.} =
  ## The default fallback removes pagination before counting. Specialized
  ## stores should override this to issue a single efficient count query.
  var unpaged = query
  unpaged.limit = 0
  unpaged.offset = 0
  result.rows = store.list(query)
  result.total = int64(store.list(unpaged).len)

method find*(store: ResourceStore, id: string): Option[ResourceRow] {.base, gcsafe.} =
  discard store
  discard id
  raise newException(ValueError, "Resource store does not implement find")

method create*(store: ResourceStore, row: ResourceRow): ResourceRow {.base, gcsafe.} =
  discard store
  discard row
  raise newException(ValueError, "Resource store does not implement create")

method update*(store: ResourceStore, id: string,
               row: ResourceRow): Option[ResourceRow] {.base, gcsafe.} =
  discard store
  discard id
  discard row
  raise newException(ValueError, "Resource store does not implement update")

method delete*(store: ResourceStore, id: string): bool {.base, gcsafe.} =
  discard store
  discard id
  raise newException(ValueError, "Resource store does not implement delete")

proc primaryKey(metadata: ModelMetadata): string =
  for field in metadata.fields:
    if field.primaryKey:
      return field.name
  "id"

proc newInMemoryResourceStore*(metadata: ModelMetadata): InMemoryResourceStore =
  ## The reference adapter is intentionally isolated per resource/test.
  new(result)
  result.metadata = metadata
  result.rows = @[]
  result.nextId = 1
  result.idField = primaryKey(metadata)

proc rowId(store: InMemoryResourceStore, row: ResourceRow): string =
  if not row.hasKey(store.idField):
    return ""
  case row[store.idField].kind
  of JString: row[store.idField].getStr()
  of JInt: $row[store.idField].getInt()
  else: ""

proc comparableSqlValue(value: SqlValue): string =
  ## Keep reference-adapter comparisons aligned with the typed query contract.
  case value.kind
  of sqlNull: ""
  of sqlText: value.text
  of sqlInteger: $value.integer
  of sqlFloat: $value.floating
  of sqlBoolean: $value.boolean

proc likeMatch(value, pattern: string): bool =
  ## Support SQL's portable `%` and `_` wildcards without introducing a
  ## backend-specific regex dependency into the in-memory reference adapter.
  var valueIndex = 0
  var patternIndex = 0
  var wildcardIndex = -1
  var wildcardMatch = 0
  while valueIndex < value.len:
    if patternIndex < pattern.len and
        (pattern[patternIndex] == '_' or pattern[patternIndex] == value[valueIndex]):
      inc valueIndex
      inc patternIndex
    elif patternIndex < pattern.len and pattern[patternIndex] == '%':
      wildcardIndex = patternIndex
      wildcardMatch = valueIndex
      inc patternIndex
    elif wildcardIndex >= 0:
      patternIndex = wildcardIndex + 1
      inc wildcardMatch
      valueIndex = wildcardMatch
    else:
      return false
  while patternIndex < pattern.len and pattern[patternIndex] == '%':
    inc patternIndex
  patternIndex == pattern.len

proc compareJsonValues(left, right: JsonNode): int =
  ## Numeric JSON values must sort numerically, not by their textual spelling.
  if left.kind in {JInt, JFloat} and right.kind in {JInt, JFloat}:
    let leftNumber = if left.kind == JInt: left.getInt().float else: left.getFloat()
    let rightNumber = if right.kind == JInt: right.getInt().float else: right.getFloat()
    if leftNumber < rightNumber: -1 elif leftNumber > rightNumber: 1 else: 0
  else:
    let leftText = if left.kind == JString: left.getStr() else: $left
    let rightText = if right.kind == JString: right.getStr() else: $right
    cmp(leftText, rightText)

method list*(store: InMemoryResourceStore,
             query: SelectQuery): seq[ResourceRow] {.gcsafe.} =
  ## The in-memory adapter is also a behavioral reference implementation. It
  ## executes the same query intent as SQL adapters so route tests can verify
  ## filtering, ordering, and pagination without requiring a live database.
  for row in store.rows:
    var matches = true
    for filter in query.filters:
      let value = if row.hasKey(filter.field): row[filter.field] else: newJNull()
      if filter.operator in {filterIsNull, filterIsNotNull}:
        let isNull = value.kind == JNull
        matches = if filter.operator == filterIsNull: isNull else: not isNull
      else:
        let filterValue = filter.value
        if value.kind == JNull:
          matches = false
        elif filterValue.kind == sqlInteger and
             value.kind in {JInt, JFloat}:
          let left = if value.kind == JInt: value.getInt().float else: value.getFloat()
          let right = filterValue.integer.float
          matches = case filter.operator
            of filterEqual: left == right
            of filterNotEqual: left != right
            of filterGreater: left > right
            of filterGreaterOrEqual: left >= right
            of filterLess: left < right
            of filterLessOrEqual: left <= right
            else: false
        elif filterValue.kind == sqlFloat and value.kind in {JInt, JFloat}:
          let left = if value.kind == JInt: value.getInt().float else: value.getFloat()
          let right = filterValue.floating
          matches = case filter.operator
            of filterEqual: left == right
            of filterNotEqual: left != right
            of filterGreater: left > right
            of filterGreaterOrEqual: left >= right
            of filterLess: left < right
            of filterLessOrEqual: left <= right
            else: false
        else:
          let left = if value.kind == JString: value.getStr() else: $value
          let right = comparableSqlValue(filterValue)
          matches = case filter.operator
            of filterEqual: left == right
            of filterNotEqual: left != right
            of filterLike: likeMatch(left, right)
            else: false
      if not matches:
        break
    if matches:
      result.add(row)

  ## Stable insertion sorting keeps equal values in creation order, while the
  ## first differing order remains the primary key like SQL ORDER BY.
  if query.orderBy.len > 0:
    var sorted: seq[ResourceRow] = @[]
    for row in result:
      var insertAt = sorted.len
      for index, existing in sorted:
        var before = false
        for order in query.orderBy:
          let candidate = if row.hasKey(order.field): row[order.field] else: newJNull()
          let current = if existing.hasKey(order.field): existing[order.field] else: newJNull()
          let comparison = compareJsonValues(candidate, current)
          if comparison != 0:
            before = if order.descending: comparison > 0 else: comparison < 0
            break
        if before:
          insertAt = index
          break
      sorted.insert(row, insertAt)
    result = sorted

  let first = min(query.offset, result.len)
  let last = if query.limit > 0: min(first + query.limit, result.len) else: result.len
  if first >= last:
    result = @[]
  elif first > 0 or last < result.len:
    result = result[first ..< last]

method listWithTotal*(store: InMemoryResourceStore,
                      query: SelectQuery): ResourceListResult {.gcsafe.} =
  ## The in-memory adapter mirrors SQL semantics by counting the same filtered
  ## query without page slicing, making route tests meaningful.
  var unpaged = query
  unpaged.limit = 0
  unpaged.offset = 0
  result.rows = store.list(query)
  result.total = int64(store.list(unpaged).len)

method find*(store: InMemoryResourceStore, id: string): Option[ResourceRow] {.gcsafe.} =
  for row in store.rows:
    if store.rowId(row) == id:
      return some(row)
  none(ResourceRow)

method create*(store: InMemoryResourceStore, row: ResourceRow): ResourceRow {.gcsafe.} =
  var stored = row
  if not stored.hasKey(store.idField):
    stored[store.idField] = newJInt(store.nextId)
    inc store.nextId
  store.rows.add(stored)
  stored

method update*(store: InMemoryResourceStore, id: string,
               row: ResourceRow): Option[ResourceRow] {.gcsafe.} =
  for index, current in store.rows:
    if store.rowId(current) == id:
      var merged = current
      for name, value in row:
        merged[name] = value
      store.rows[index] = merged
      return some(merged)
  none(ResourceRow)

method delete*(store: InMemoryResourceStore, id: string): bool {.gcsafe.} =
  for index, row in store.rows:
    if store.rowId(row) == id:
      store.rows.delete(index)
      return true
  false

proc newCrudResource*(metadata: ModelMetadata, store: ResourceStore,
                      responsePolicy = defaultSerializationPolicy(),
                      cursorSecret = "", cursorTtlSeconds: int64 = 0): CrudResource =
  if store.isNil:
    raise newException(ValueError, "CRUD resource requires a store")
  if cursorTtlSeconds < 0:
    raise newException(ValueError, "CRUD cursor TTL cannot be negative")
  CrudResource(metadata: metadata, store: store, responsePolicy: responsePolicy,
    cursorSecret: cursorSecret, cursorTtlSeconds: cursorTtlSeconds)

proc jsonValues(metadata: ModelMetadata, document: JsonNode): ResourceRow =
  if document.kind != JObject:
    raise newException(ValueError, "CRUD request body must be a JSON object")
  for name, value in document:
    var resolved = name
    for field in metadata.fields:
      if field.name == name or field.jsonName == name:
        resolved = field.name
        break
    result[resolved] = value

proc responseDocument(resource: CrudResource, row: ResourceRow): JsonNode =
  let serialized = serializeModel(resource.metadata, row,
    resource.responsePolicy)
  if not serialized.valid:
    raise newException(ValueError, "Stored resource row failed serialization")
  serialized.document

proc inputPolicy(resource: CrudResource): SerializationPolicy =
  ## Request DTOs may contain write-only sensitive fields, while unknown fields
  ## must never be silently persisted through a CRUD convention.
  result = resource.responsePolicy
  result.excludeSensitive = false
  result.rejectUnknownFields = true

proc generatedKeyPlaceholder(field: ModelField): JsonNode =
  ## Let an auto-generated primary key pass required-field validation without
  ## pretending the placeholder is persisted.
  case field.kind
  of modelInteger: newJInt(0)
  of modelFloat: newJFloat(0.0)
  of modelBoolean: newJBool(false)
  of modelJson, modelFile: newJObject()
  of modelString, modelDateTime, modelUuid, modelReference: newJString("")

proc listResponse*(resource: CrudResource,
                   query = SelectQuery()): Response {.gcsafe.} =
  var document = newJArray()
  for row in resource.store.list(query):
    if query.columns.len == 0:
      document.add(responseDocument(resource, row))
    else:
      let serialized = serializeProjection(resource.metadata, row, query.columns,
        resource.responsePolicy)
      if not serialized.valid:
        raise newException(ValueError, "Stored resource row failed projection")
      document.add(serialized.document)
  jsonResponse(document)

proc listResponseWithTotal*(resource: CrudResource,
                            query = SelectQuery()): Response {.gcsafe.} =
  ## Opt-in envelope preserves backwards compatibility for existing clients.
  let page = resource.store.listWithTotal(query)
  var items = newJArray()
  for row in page.rows:
    if query.columns.len == 0:
      items.add(responseDocument(resource, row))
    else:
      let serialized = serializeProjection(resource.metadata, row, query.columns,
        resource.responsePolicy)
      if not serialized.valid:
        raise newException(ValueError, "Stored resource row failed projection")
      items.add(serialized.document)
  var document = newJObject()
  document["items"] = items
  document["total"] = newJInt(page.total)
  jsonResponse(document)

proc listResponseWithCursor*(resource: CrudResource,
                             query: SelectQuery,
                             cursor: CursorPagination,
                             includeTotal = false): Response {.gcsafe.} =
  ## Fetch one look-ahead row so the next cursor is emitted only when another
  ## page exists. The extra row is never serialized to the client.
  if query.limit < 1:
    raise newException(ValueError, "Cursor response requires a positive page size")
  var lookAhead = query
  lookAhead.limit = query.limit + 1
  var rows = resource.store.list(lookAhead)
  let hasNext = rows.len > query.limit
  if hasNext:
    rows.setLen(query.limit)
  var items = newJArray()
  var cursorField: Option[ModelField] = none(ModelField)
  for field in resource.metadata.fields:
    if field.name == cursor.field:
      cursorField = some(field)
      break
  for row in rows:
    if query.columns.len == 0:
      items.add(responseDocument(resource, row))
    else:
      let serialized = serializeProjection(resource.metadata, row, query.columns,
        resource.responsePolicy)
      if not serialized.valid:
        raise newException(ValueError, "Stored resource row failed projection")
      items.add(serialized.document)
  var document = newJObject()
  document["items"] = items
  document["next_cursor"] = newJNull()
  if hasNext and cursorField.isSome and rows.len > 0 and
     rows[^1].hasKey(cursor.field):
    document["next_cursor"] = newJString(
      cursorTokenFor(cursorField.get(), rows[^1][cursor.field],
        resource.cursorSecret, resource.cursorTtlSeconds))
  if includeTotal:
    document["total"] = newJInt(resource.store.listWithTotal(query).total)
  jsonResponse(document)

proc getResponse*(resource: CrudResource, id: string): Response {.gcsafe.} =
  let row = resource.store.find(id)
  if row.isNone:
    return textResponse("Not Found", Http404)
  jsonResponse(responseDocument(resource, row.get()))

proc createResponse*(resource: CrudResource, body: string): Response {.gcsafe.} =
  try:
    let values = jsonValues(resource.metadata, parseJson(body))
    var validationValues = values
    for field in resource.metadata.fields:
      if field.primaryKey and not validationValues.hasKey(field.name):
        validationValues[field.name] = generatedKeyPlaceholder(field)
    let validation = serializeModel(resource.metadata, validationValues,
      resource.inputPolicy())
    if not validation.valid:
      return textResponse("Invalid resource body", Http400)
    let row = resource.store.create(values)
    jsonResponse(responseDocument(resource, row), Http201)
  except CatchableError:
    textResponse("Invalid resource body", Http400)

proc updateResponse*(resource: CrudResource, id, body: string): Response {.gcsafe.} =
  try:
    let values = jsonValues(resource.metadata, parseJson(body))
    let validation = serializePatch(resource.metadata, values, resource.inputPolicy())
    if not validation.valid:
      return textResponse("Invalid resource body", Http400)
    let updated = resource.store.update(id, values)
    if updated.isNone:
      return textResponse("Not Found", Http404)
    jsonResponse(responseDocument(resource, updated.get()))
  except CatchableError:
    textResponse("Invalid resource body", Http400)

proc deleteResponse*(resource: CrudResource, id: string): Response {.gcsafe.} =
  if resource.store.delete(id):
    return newResponse(Http204)
  textResponse("Not Found", Http404)

proc registerCrudRoutes*(app: Application, resource: CrudResource,
                         prefix, name: string) =
  ## Register conventional collection/detail routes while keeping handlers thin.
  if prefix.len == 0 or name.len == 0:
    raise newException(ValueError, "CRUD route requires prefix and name")
  app.get(prefix, name & ".list",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      var options = defaultQueryComponentOptions()
      options.cursorField = primaryKey(resource.metadata)
      options.cursorSecret = resource.cursorSecret
      options.cursorTtlSeconds = resource.cursorTtlSeconds
      let parsed = request.parseQueryComponent(resource.metadata.fields, options)
      if not parsed.valid:
        return request.problemResponseFor(Http400, "Invalid query",
          "One or more query parameters are invalid", parsed.errors)
      if parsed.cursor.isSome:
        return listResponseWithCursor(resource, parsed.query,
          parsed.cursor.get(), parsed.includeTotal)
      if parsed.includeTotal:
        return listResponseWithTotal(resource, parsed.query)
      return listResponse(resource, parsed.query))
  app.post(prefix, name & ".create",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      return createResponse(resource, request.body))
  app.get(prefix & "/:id", name & ".get",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      return getResponse(resource, request.pathParams.getOrDefault("id")))
  app.addRoute("PUT", prefix & "/:id", name & ".update",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      return updateResponse(resource, request.pathParams.getOrDefault("id"),
        request.body))
  app.addRoute("DELETE", prefix & "/:id", name & ".delete",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      return deleteResponse(resource, request.pathParams.getOrDefault("id")))
