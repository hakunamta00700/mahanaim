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
import ./serialization

type
  ResourceRow* = Table[string, JsonNode]

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

method list*(store: ResourceStore,
             query: SelectQuery): seq[ResourceRow] {.base, gcsafe.} =
  discard store
  discard query
  raise newException(ValueError, "Resource store does not implement list")

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

method list*(store: InMemoryResourceStore,
             query: SelectQuery): seq[ResourceRow] {.gcsafe.} =
  ## Pagination is applied by the query contract; this reference adapter keeps
  ## ordering deterministic and leaves filtering to future backend adapters.
  discard query
  for row in store.rows:
    result.add(row)

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
                      responsePolicy = defaultSerializationPolicy()): CrudResource =
  if store.isNil:
    raise newException(ValueError, "CRUD resource requires a store")
  CrudResource(metadata: metadata, store: store, responsePolicy: responsePolicy)

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
    document.add(responseDocument(resource, row))
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
      discard request
      return listResponse(resource))
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
