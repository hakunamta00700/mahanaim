## Metadata-driven admin registry.
##
## This first admin slice deliberately composes existing CRUD, form, and
## security contracts instead of introducing a second persistence or template
## system. It provides a secure registration boundary, JSON CRUD routes, an
## server-rendered CRUD forms, and an append-only audit trail; richer
## permissions and layouts remain extension points.

import std/[asyncdispatch, httpcore, json, options, strutils, tables]
import ./application
import ./authorization
import ./core
import ./database
import ./forms
import ./model_schema
import ./models
import ./query_components
import ./resources
import ./security
import ./serialization
import ./sqlite_adapter
import ./templates
import ./validation

type
  AdminAuthorization* = proc(request: Request): bool {.gcsafe.}
  AdminFormLayoutContext* = object
    ## A renderer receives only the normalized form and resource identity; it
    ## cannot bypass authorization or persistence by mutating AdminResource.
    resourceName*: string
    action*: string
    form*: FormState
  AdminFormLayoutRenderer* = proc(context: AdminFormLayoutContext): Response
    {.gcsafe.}

  AdminAuditEvent* = object
    ## Audit records contain the stable resource/action identity, not request
    ## bodies or secrets, so the default trail is safe to inspect and export.
    action*: string
    resource*: string
    identifier*: string
    actor*: string

  AdminAuditStore* = ref object of RootObj
    ## Audit persistence is an adapter boundary: applications can replace the
    ## reference store with an append-only database or external log sink.

  InMemoryAdminAuditStore* = ref object of AdminAuditStore
    ## The default store is deterministic for tests and local development. Its
    ## events are only exposed through snapshots, never through the backing
    ## sequence, so callers cannot rewrite the audit history accidentally.
    events: seq[AdminAuditEvent]

  SqliteAdminAuditStore* = ref object of AdminAuditStore
    ## A small durable first-party audit adapter. It owns its connection only
    ## when built from a path; shared adapters stay owned by the application.
    adapter*: SqliteDatabaseAdapter
    ownsAdapter: bool

  AdminInline* = ref object
    ## A related child resource that may be edited as one formset beneath a
    ## parent. The parent field is always assigned by the server.
    name*: string
    metadata*: ModelMetadata
    resource*: CrudResource
    parentField*: string
    readOnlyFields*: seq[string]

  AdminResource* = ref object
    ## One registered admin resource owns route and form policy while storage
    ## remains behind the existing ResourceStore contract.
    name*: string
    prefix*: string
    metadata*: ModelMetadata
    resource*: CrudResource
    authorize: AdminAuthorization
    authorizationPolicy*: AuthorizationPolicy
    permissionResource*: string
    formPolicy*: SecurityPolicy
    ## Admin list behavior is configurable per resource while parsing and
    ## validating query syntax remains owned by the shared component.
    queryOptions*: QueryComponentOptions
    ## These fields are enforced at the admin boundary, not left to a store
    ## implementation, so every backend gets the same write protection.
    readOnlyFields*: seq[string]
    ## Canonical metadata names used when no explicit `fields` query is given.
    customColumns*: seq[string]
    ## Optional presentation hook. Route, authorization, and audit ownership
    ## remain in this module while applications control the final HTML shell.
    formLayout*: AdminFormLayoutRenderer
    inlines*: seq[AdminInline]

  AdminRegistry* = ref object
    ## Registration is application-owned and isolated from global plugin state.
    resources*: seq[AdminResource]
    auditStore*: AdminAuditStore
    ## Kept as a compatibility projection for existing consumers. New code
    ## should use auditEvents(), which reads the configured store snapshot.
    auditLog*: seq[AdminAuditEvent]

method appendAuditEvent*(store: AdminAuditStore,
                         event: AdminAuditEvent) {.base, gcsafe.} =
  ## A custom durable backend must opt into the append-only contract explicitly.
  discard store
  discard event
  raise newException(ValueError, "Admin audit store does not implement append")

method auditEvents*(store: AdminAuditStore): seq[AdminAuditEvent] {.base, gcsafe.} =
  ## A snapshot prevents readers from obtaining a mutable persistence buffer.
  discard store
  raise newException(ValueError, "Admin audit store does not implement snapshot")

method close*(store: AdminAuditStore) {.base, gcsafe.} =
  ## Stores without external resources require no shutdown work.
  discard store

method appendAuditEvent*(store: InMemoryAdminAuditStore,
                         event: AdminAuditEvent) {.gcsafe.} =
  store.events.add(event)

method auditEvents*(store: InMemoryAdminAuditStore): seq[AdminAuditEvent] {.gcsafe.} =
  store.events

proc initializeAuditSchema(adapter: SqliteDatabaseAdapter) =
  ## Schema and mutations use fixed SQL plus bound values only. The store has
  ## no public update/delete operation, preserving an append-only API contract.
  discard adapter.executeRaw(newRawSqlQuery(
    "CREATE TABLE IF NOT EXISTS mahanaim_admin_audit " &
    "(sequence INTEGER PRIMARY KEY AUTOINCREMENT, " &
    "action TEXT NOT NULL, resource TEXT NOT NULL, " &
    "identifier TEXT NOT NULL, actor TEXT NOT NULL)"))

proc newSqliteAdminAuditStore*(adapter: SqliteDatabaseAdapter,
                               ownsAdapter = false): SqliteAdminAuditStore =
  ## Bind durable audit history to a caller-selected SQLite connection.
  if adapter.isNil:
    raise newException(ValueError, "SQLite audit store requires an adapter")
  initializeAuditSchema(adapter)
  SqliteAdminAuditStore(adapter: adapter, ownsAdapter: ownsAdapter)

proc newSqliteAdminAuditStore*(path: string): SqliteAdminAuditStore =
  ## Open an application-owned SQLite audit database at an explicit path.
  let adapter = newSqliteDatabaseAdapter(path)
  try:
    result = newSqliteAdminAuditStore(adapter, ownsAdapter = true)
  except CatchableError:
    adapter.close()
    raise

method appendAuditEvent*(store: SqliteAdminAuditStore,
                         event: AdminAuditEvent) {.gcsafe.} =
  if store.isNil or store.adapter.isNil:
    raise newException(ValueError, "SQLite audit store is closed")
  discard store.adapter.executeRaw(newRawSqlQuery(
    "INSERT INTO mahanaim_admin_audit " &
    "(action, resource, identifier, actor) VALUES (?, ?, ?, ?)",
    [textValue(event.action), textValue(event.resource),
     textValue(event.identifier), textValue(event.actor)]))

method auditEvents*(store: SqliteAdminAuditStore): seq[AdminAuditEvent] {.gcsafe.} =
  if store.isNil or store.adapter.isNil:
    raise newException(ValueError, "SQLite audit store is closed")
  let rows = store.adapter.executeRaw(newRawSqlQuery(
    "SELECT action, resource, identifier, actor " &
    "FROM mahanaim_admin_audit ORDER BY sequence ASC")).rows
  for row in rows:
    result.add(AdminAuditEvent(action: row[0].text, resource: row[1].text,
      identifier: row[2].text, actor: row[3].text))

method close*(store: SqliteAdminAuditStore) {.gcsafe.} =
  if store.isNil:
    return
  if store.ownsAdapter and not store.adapter.isNil:
    store.adapter.close()
  store.adapter = nil

proc newInMemoryAdminAuditStore*(): InMemoryAdminAuditStore =
  ## Provide a small reference adapter without coupling admin routes to a DB.
  new(result)
  result.events = @[]

proc newAdminRegistry*(auditStore: AdminAuditStore = nil): AdminRegistry =
  ## Start with no routes; plugins or the application add explicit resources.
  new(result)
  result.resources = @[]
  result.auditLog = @[]
  result.auditStore = if auditStore.isNil:
    newInMemoryAdminAuditStore()
  else:
    auditStore

proc auditEvents*(registry: AdminRegistry): seq[AdminAuditEvent] =
  ## Expose a stable read snapshot while preserving the old auditLog field.
  if registry.isNil or registry.auditStore.isNil:
    return @[]
  registry.auditStore.auditEvents()

proc registerAdminResource*(registry: AdminRegistry, name, prefix: string,
                            metadata: ModelMetadata, store: ResourceStore,
                            authorize: AdminAuthorization,
                            formPolicy = defaultSecurityPolicy(),
                            authorizationPolicy: AuthorizationPolicy = nil,
                            queryOptions = defaultQueryComponentOptions(),
                            readOnlyFields: seq[string] = @[],
                            customColumns: seq[string] = @[],
                            formLayout: AdminFormLayoutRenderer = nil) =
  ## Requiring an authorization callback prevents an accidentally public admin
  ## surface when a developer forgets to configure authentication.
  if registry.isNil or name.strip().len == 0 or prefix.len == 0 or
     prefix[0] != '/' or authorize.isNil:
    raise newException(ValueError,
      "Admin resource requires name, absolute prefix, and authorization")
  for existing in registry.resources:
    if existing.name == name or existing.prefix == prefix:
      raise newException(ValueError, "Duplicate admin resource: " & name)
  proc canonicalFields(names: seq[string], label: string): seq[string] =
    for requested in names:
      var found = false
      for field in metadata.fields:
        if field.name == requested or field.jsonName == requested or
            field.columnName == requested:
          if field.name in result:
            raise newException(ValueError, "Duplicate admin " & label & ": " & requested)
          result.add(field.name)
          found = true
          break
      if not found:
        raise newException(ValueError, "Unknown admin " & label & ": " & requested)
  let canonicalReadOnly = canonicalFields(readOnlyFields, "read-only field")
  let canonicalColumns = canonicalFields(customColumns, "custom column")
  registry.resources.add(AdminResource(name: name, prefix: prefix,
    metadata: metadata, resource: newCrudResource(metadata, store),
    authorize: authorize, authorizationPolicy: authorizationPolicy,
    permissionResource: name, formPolicy: formPolicy,
    queryOptions: queryOptions, readOnlyFields: canonicalReadOnly,
    customColumns: canonicalColumns, formLayout: formLayout, inlines: @[]))

proc adminPrimaryKey(metadata: ModelMetadata): string =
  for field in metadata.fields:
    if field.primaryKey:
      return field.name
  "id"

proc canonicalAdminFields(metadata: ModelMetadata, names: seq[string],
                          label: string): seq[string] =
  for requested in names:
    var found = false
    for field in metadata.fields:
      if field.name == requested or field.jsonName == requested or
          field.columnName == requested:
        if field.name in result:
          raise newException(ValueError, "Duplicate admin " & label & ": " & requested)
        result.add(field.name)
        found = true
        break
    if not found:
      raise newException(ValueError, "Unknown admin " & label & ": " & requested)

proc registerAdminInline*(registry: AdminRegistry, resourceName, name: string,
                          metadata: ModelMetadata, store: ResourceStore,
                          parentField: string,
                          readOnlyFields: seq[string] = @[]) =
  ## Register related children explicitly. No relation is inferred from route
  ## names, and the server—not the client—owns the foreign-key assignment.
  if registry.isNil or resourceName.strip().len == 0 or name.strip().len == 0 or
      name.contains('/') or store.isNil:
    raise newException(ValueError,
      "Admin inline requires resource, safe name, metadata, and store")
  var parent: AdminResource = nil
  for candidate in registry.resources:
    if candidate.name == resourceName:
      parent = candidate
      break
  if parent.isNil:
    raise newException(ValueError, "Unknown admin resource: " & resourceName)
  var resolvedParentField = ""
  for field in metadata.fields:
    if field.name == parentField or field.jsonName == parentField or
        field.columnName == parentField:
      resolvedParentField = field.name
      break
  if resolvedParentField.len == 0:
    raise newException(ValueError, "Unknown admin inline parent field: " & parentField)
  for inline in parent.inlines:
    if inline.name == name:
      raise newException(ValueError, "Duplicate admin inline: " & name)
  let protectedFields = canonicalAdminFields(metadata, readOnlyFields,
    "inline read-only field")
  parent.inlines.add(AdminInline(name: name, metadata: metadata,
    resource: newCrudResource(metadata, store), parentField: resolvedParentField,
    readOnlyFields: protectedFields))

proc recordAudit(registry: AdminRegistry, resource, action, identifier,
                 actor: string) =
  ## Keep audit creation centralized so every mutating route follows one shape.
  let event = AdminAuditEvent(action: action, resource: resource,
    identifier: identifier, actor: actor)
  registry.auditStore.appendAuditEvent(event)
  ## Compatibility projection is intentionally written only after the store;
  ## a failed durable append must never look like a successful audit locally.
  registry.auditLog.add(event)

proc forbiddenResponse(): Response =
  ## Do not reveal whether a protected resource exists to unauthorized callers.
  textResponse("Admin authorization required", Http403)

proc adminRedirect(location: string): Response =
  ## Redirects from browser forms still carry a representation type so the
  ## common Accept negotiation policy treats the 3xx response as renderable.
  result = redirectResponse(location)
  result.headers["content-type"] = "text/html; charset=utf-8"

proc adminAuthorized(resource: AdminResource, request: Request,
                     action, objectId: string): bool =
  ## The legacy callback remains a coarse application boundary; when a policy
  ## is configured, it supplies the composable role/group/object decision too.
  if not resource.authorize(request):
    return false
  resource.authorizationPolicy.isNil or resource.authorizationPolicy.allows(
    request, resource.permissionResource, action, objectId)

proc adminForm(resource: AdminResource, request: Request): Response =
  ## Build a minimal create form from the same metadata-derived schema used by
  ## API validation and OpenAPI; custom widgets can replace this helper later.
  var form = FormState(fields: @[], errors: @[])
  for field in modelInputSchema(resource.metadata, flBody,
                                includePrimaryKey = false):
    if field.name in resource.readOnlyFields:
      continue
    form.fields.add(FormFieldState(name: field.name, label: field.name,
      inputType: field.inputType, required: field.required, value: "",
      errors: @[]))
  if resource.formLayout != nil:
    return resource.formLayout(AdminFormLayoutContext(
      resourceName: resource.name, action: resource.prefix, form: form))
  htmlResponse(renderForm(form, request, action = resource.prefix,
    csrfPolicy = resource.formPolicy))

proc adminListColumns(resource: AdminResource, query: SelectQuery): seq[string] =
  ## Resolve one visible column set for HTML headings and cell serialization.
  ## Sensitive fields are filtered before rendering, even when a caller asks
  ## for them explicitly through the shared query component.
  let requested = if query.columns.len > 0: query.columns
    elif resource.customColumns.len > 0: resource.customColumns
    else: @[]
  for field in resource.metadata.fields:
    if field.sensitive and resource.resource.responsePolicy.excludeSensitive:
      continue
    if requested.len == 0 or field.name in requested:
      result.add(field.name)

proc adminDisplayValue(document: JsonNode, field: ModelField): string =
  ## Keep HTML rendering independent from JSON node formatting while preserving
  ## a readable representation for scalar and structured values.
  if not document.hasKey(field.jsonName):
    return ""
  let value = document[field.jsonName]
  if value.kind == JNull:
    return ""
  if value.kind == JString:
    return escapeHtml(value.getStr())
  escapeHtml($value)

proc adminListHtml(resource: AdminResource, query: SelectQuery): Response =
  ## Server-rendered list output is an optional representation of the same
  ## query result as JSON. Keeping it here avoids a second store or auth path;
  ## response negotiation selects it only for an HTML Accept header.
  let columns = resource.adminListColumns(query)
  var body = "<!doctype html><html><head><title>" &
    escapeHtml(resource.name) & "</title></head><body>"
  body.add("<main data-resource=\"" & escapeHtml(resource.name) & "\">")
  body.add("<h1>" & escapeHtml(resource.name) & "</h1>")
  body.add("<a href=\"" & escapeHtml(resource.prefix & "/new") &
    "\">New</a><table><thead><tr>")
  for column in columns:
    let field = resource.metadata.field(column)
    if field.isSome:
      body.add("<th>" & escapeHtml(field.get().name) & "</th>")
  body.add("</tr></thead><tbody>")
  for row in resource.resource.store.list(query):
    let serialized = serializeProjection(resource.metadata, row, columns,
      resource.resource.responsePolicy)
    if not serialized.valid:
      return textResponse("Stored resource row failed serialization", Http500)
    body.add("<tr>")
    for column in columns:
      let field = resource.metadata.field(column)
      if field.isSome:
        body.add("<td>" & adminDisplayValue(serialized.document,
          field.get()) & "</td>")
    body.add("</tr>")
  body.add("</tbody></table></main></body></html>")
  htmlResponse(body)

proc adminDocumentRawValue(document: JsonNode, field: ModelField): string =
  ## Convert a serialized field into a raw scalar value for a form control.
  ## Escaping is deliberately deferred to the final HTML context so a value
  ## is not escaped once for display and then escaped a second time as an
  ## input attribute.
  if not document.hasKey(field.jsonName):
    return ""
  let value = document[field.jsonName]
  if value.kind == JNull:
    return ""
  if value.kind == JString:
    return value.getStr()
  $value

proc adminDocumentValue(document: JsonNode, field: ModelField): string =
  ## Display values are escaped at the HTML text-node boundary.
  escapeHtml(adminDocumentRawValue(document, field))

proc adminEditForm(resource: AdminResource, request: Request, identifier: string,
                   document: JsonNode): string =
  ## The edit form is derived from the same input schema as the create form.
  ## Primary keys, read-only fields, and sensitive response-only values never
  ## become writable controls by accident.
  var form = FormState(fields: @[], errors: @[])
  for fieldSpec in modelInputSchema(resource.metadata, flBody,
                                    includePrimaryKey = false):
    if fieldSpec.name in resource.readOnlyFields:
      continue
    let modelField = resource.metadata.field(fieldSpec.name)
    if modelField.isNone:
      continue
    form.fields.add(FormFieldState(name: fieldSpec.name,
      label: fieldSpec.name, inputType: fieldSpec.inputType,
      required: fieldSpec.required,
      value: adminDocumentRawValue(document, modelField.get()),
      errors: @[]))
  let action = resource.prefix & "/" & identifier
  if resource.formLayout != nil:
    return resource.formLayout(AdminFormLayoutContext(
      resourceName: resource.name, action: action, form: form)).body
  renderForm(form, request, action = action, httpMethod = "post",
    csrfPolicy = resource.formPolicy)

proc adminDetailHtml(resource: AdminResource, request: Request,
                     identifier: string): Response =
  ## Detail pages expose a server-rendered edit/delete surface while the
  ## JSON representation remains available through the first response
  ## variant. No client-side application or second authorization path is
  ## introduced; the existing admin route owns the resource lookup.
  let found = resource.resource.store.find(identifier)
  if found.isNone:
    return textResponse("Not Found", Http404)
  let serialized = serializeModel(resource.metadata, found.get(),
    resource.resource.responsePolicy)
  if not serialized.valid:
    return textResponse("Stored resource row failed serialization", Http500)
  var body = "<!doctype html><html><head><title>" &
    escapeHtml(resource.name) & "</title></head><body>"
  body.add("<main data-resource=\"" & escapeHtml(resource.name) &
    "\" data-id=\"" & escapeHtml(identifier) & "\">")
  body.add("<a href=\"" & escapeHtml(resource.prefix) &
    "\">Back</a><h1>" & escapeHtml(resource.name) & "</h1><dl>")
  for field in resource.metadata.fields:
    if field.sensitive and resource.resource.responsePolicy.excludeSensitive:
      continue
    body.add("<dt>" & escapeHtml(field.name) & "</dt><dd>" &
      adminDocumentValue(serialized.document, field) & "</dd>")
  body.add("</dl>")
  body.add(resource.adminEditForm(request, identifier, serialized.document))
  body.add("<form action=\"" & escapeHtml(resource.prefix & "/" &
    identifier & "/delete") & "\" method=\"post\">")
  body.add("<button type=\"submit\">Delete</button></form>")
  body.add("</main></body></html>")
  htmlResponse(body)

proc adminFormResponse(resource: AdminResource, request: Request,
                       action: string, form: FormState): Response =
  ## Both create and edit submissions render validation errors through the
  ## same layout hook. The hook can replace markup without gaining access to
  ## storage or authorization decisions.
  if resource.formLayout != nil:
    return resource.formLayout(AdminFormLayoutContext(
      resourceName: resource.name, action: action, form: form))
  htmlResponse(renderForm(form, request, action = action,
    httpMethod = "post", csrfPolicy = resource.formPolicy))

proc adminFormJson(resource: AdminResource, request: Request):
    tuple[valid: bool, body: string, form: FormState] =
  ## URL-encoded browser fields enter the normal validation contract first;
  ## only then are they converted to typed JSON for the existing CRUD layer.
  let schema = modelInputSchema(resource.metadata, flBody,
    includePrimaryKey = false)
  result.form = bindForm(request, schema)
  let validation = request.validate(schema)
  result.valid = validation.errors.len == 0
  if not result.valid:
    return
  var document = newJObject()
  for field in schema:
    if not validation.values.hasKey(field.name):
      continue
    let raw = validation.values[field.name]
    case field.inputType
    of itString:
      document[field.name] = newJString(raw)
    of itInteger:
      document[field.name] = newJInt(parseInt(raw))
    of itFloat:
      document[field.name] = newJFloat(parseFloat(raw))
    of itBoolean:
      document[field.name] = newJBool(raw.toLowerAscii() in ["true", "1"])
    of itJson:
      document[field.name] = parseJson(raw)
  result.body = $document

proc adminWritableBody(resource: AdminResource, body: string): string =
  ## Strip protected fields before a CRUD resource sees input. Parsing errors
  ## remain the resource's responsibility so its existing problem envelope is
  ## preserved for malformed JSON and non-object bodies.
  try:
    let document = parseJson(body)
    if document.kind != JObject:
      return body
    for field in resource.metadata.fields:
      if field.name in resource.readOnlyFields:
        document.delete(field.name)
        if field.jsonName != field.name:
          document.delete(field.jsonName)
    $document
  except CatchableError:
    body

proc bulkDeleteIds(body: string): Option[seq[string]] =
  ## Parse the bulk command before mutating anything so authorization and
  ## validation can be completed for the whole batch atomically at the route
  ## boundary. Persistence adapters still own transaction semantics.
  try:
    let document = parseJson(body)
    if document.kind != JObject or not document.hasKey("ids") or
        document["ids"].kind != JArray or document["ids"].len == 0 or
        document["ids"].len > 100:
      return none(seq[string])
    result = some(newSeq[string]())
    for item in document["ids"]:
      case item.kind
      of JString:
        if item.getStr().strip().len == 0: return none(seq[string])
        result.get().add(item.getStr())
      of JInt:
        result.get().add($item.getInt())
      else:
        return none(seq[string])
    return result
  except CatchableError:
    none(seq[string])

proc inlineIdentifier(value: JsonNode): Option[string] =
  case value.kind
  of JString:
    if value.getStr().strip().len > 0: some(value.getStr()) else: none(string)
  of JInt: some($value.getInt())
  else: none(string)

proc relationMatches(value: JsonNode, parentId: string): bool =
  ## Model references may be string or integer JSON values; compare their
  ## stable wire identity without turning the identifier into SQL text.
  let identifier = inlineIdentifier(value)
  identifier.isSome and identifier.get() == parentId

proc inlineInputPolicy(): SerializationPolicy =
  result = defaultSerializationPolicy()
  result.excludeSensitive = false
  result.rejectUnknownFields = true

proc inlineMutations(inline: AdminInline, parentId, body: string):
    Option[seq[ResourceMutation]] =
  ## Parse and validate every row before passing anything to the atomic store.
  ## That keeps invalid payloads and cross-parent edits from changing a prior
  ## formset row even for a store with an expensive transaction boundary.
  try:
    let document = parseJson(body)
    if document.kind != JObject or not document.hasKey("rows") or
        document["rows"].kind != JArray or document["rows"].len == 0 or
        document["rows"].len > 100:
      return none(seq[ResourceMutation])
    let idField = adminPrimaryKey(inline.metadata)
    var seenIds: seq[string] = @[]
    var mutations: seq[ResourceMutation] = @[]
    for submitted in document["rows"]:
      if submitted.kind != JObject:
        return none(seq[ResourceMutation])
      var id = none(string)
      if submitted.hasKey(idField):
        id = inlineIdentifier(submitted[idField])
      if id.isNone:
        for field in inline.metadata.fields:
          if field.primaryKey and field.jsonName != idField and
              submitted.hasKey(field.jsonName):
            id = inlineIdentifier(submitted[field.jsonName])
            break
      let deleting = submitted.hasKey("_delete") and
        submitted["_delete"].kind == JBool and submitted["_delete"].getBool()
      if deleting and id.isNone:
        return none(seq[ResourceMutation])
      if id.isSome:
        if id.get() in seenIds:
          return none(seq[ResourceMutation])
        seenIds.add(id.get())
        let existing = inline.resource.store.find(id.get())
        if existing.isNone or not existing.get().hasKey(inline.parentField) or
            not relationMatches(existing.get()[inline.parentField], parentId):
          return none(seq[ResourceMutation])
      if deleting:
        mutations.add(ResourceMutation(kind: resourceDelete, id: id.get()))
        continue

      var values = initTable[string, JsonNode]()
      for name, value in submitted:
        if name == "_delete":
          continue
        var resolved = name
        for field in inline.metadata.fields:
          if field.name == name or field.jsonName == name:
            resolved = field.name
            break
        if resolved == idField or resolved in inline.readOnlyFields:
          continue
        if resolved == inline.parentField:
          if not relationMatches(value, parentId):
            return none(seq[ResourceMutation])
          continue
        values[resolved] = value
      ## The relationship is server-managed on both creation and update.
      values[inline.parentField] = newJString(parentId)
      if id.isSome:
        if not serializePatch(inline.metadata, values, inlineInputPolicy()).valid:
          return none(seq[ResourceMutation])
        mutations.add(ResourceMutation(kind: resourceUpdate, id: id.get(), row: values))
      else:
        var validationValues = values
        for field in inline.metadata.fields:
          if field.primaryKey and not validationValues.hasKey(field.name):
            case field.kind
            of modelInteger: validationValues[field.name] = newJInt(0)
            of modelFloat: validationValues[field.name] = newJFloat(0.0)
            of modelBoolean: validationValues[field.name] = newJBool(false)
            of modelJson, modelFile: validationValues[field.name] = newJObject()
            of modelString, modelDateTime, modelUuid, modelReference:
              validationValues[field.name] = newJString("")
        if not serializeModel(inline.metadata, validationValues,
                              inlineInputPolicy()).valid:
          return none(seq[ResourceMutation])
        mutations.add(ResourceMutation(kind: resourceCreate, row: values))
    some(mutations)
  except CatchableError:
    none(seq[ResourceMutation])

proc registerResourceRoutes(app: Application, registry: AdminRegistry,
                            resource: AdminResource) =
  ## Route closures capture one immutable definition so loop registration cannot
  ## accidentally make every resource point at the final loop item.
  let current = resource
  app.get(current.prefix, "admin." & current.name & ".list",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      if not adminAuthorized(current, request, "list", ""):
        return forbiddenResponse()
      var parsed = request.parseQueryComponent(current.metadata.fields,
        current.queryOptions)
      if not parsed.valid:
        return request.problemResponseFor(Http400, "Invalid query",
          "One or more query parameters are invalid", parsed.errors)
      if parsed.query.columns.len == 0 and current.customColumns.len > 0:
        parsed.query.columns = current.customColumns
      return responseVariants([
        listResponse(current.resource, parsed.query),
        adminListHtml(current, parsed.query)]))
  app.get(current.prefix & "/new", "admin." & current.name & ".form",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      if not adminAuthorized(current, request, "create", ""):
        return forbiddenResponse()
      return adminForm(current, request))
  app.post(current.prefix, "admin." & current.name & ".create",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      if not adminAuthorized(current, request, "create", ""):
        return forbiddenResponse()
      let contentType = request.header("content-type")
      if contentType.isSome and contentType.get().toLowerAscii().startsWith(
          "application/x-www-form-urlencoded"):
        let submitted = current.adminFormJson(request)
        if not submitted.valid:
          return adminFormResponse(current, request, current.prefix,
            submitted.form)
        let formResponse = createResponse(current.resource, submitted.body)
        if formResponse.status == Http201:
          registry.recordAudit(current.name, "create", "",
            request.auth.subject)
          return adminRedirect(current.prefix)
        return formResponse
      let response = createResponse(current.resource,
        current.adminWritableBody(request.body))
      if response.status == Http201:
        registry.recordAudit(current.name, "create", "", request.auth.subject)
      return response)
  app.post(current.prefix & "/bulk-delete", "admin." & current.name & ".bulk-delete",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      let identifiers = bulkDeleteIds(request.body)
      if identifiers.isNone:
        return textResponse("Invalid bulk delete payload", Http400)
      for identifier in identifiers.get():
        if not adminAuthorized(current, request, "delete", identifier):
          return forbiddenResponse()
      var deleted = 0
      for identifier in identifiers.get():
        if current.resource.store.delete(identifier):
          inc deleted
          registry.recordAudit(current.name, "delete", identifier,
            request.auth.subject)
      return jsonResponse(%*{"deleted": deleted})
    )
  for inline in current.inlines:
    let currentInline = inline
    app.post(current.prefix & "/:id/inlines/" & currentInline.name,
      "admin." & current.name & ".inline." & currentInline.name & ".formset",
      proc(request: Request): Future[Response] {.async, gcsafe.} =
        let identifier = request.pathParams.getOrDefault("id")
        if not adminAuthorized(current, request, "update", identifier):
          return forbiddenResponse()
        if current.resource.store.find(identifier).isNone:
          return textResponse("Not Found", Http404)
        let mutations = inlineMutations(currentInline, identifier, request.body)
        if mutations.isNone:
          return textResponse("Invalid inline formset payload", Http400)
        try:
          currentInline.resource.store.mutateAtomically(mutations.get())
          registry.recordAudit(current.name,
            "inline-formset:" & currentInline.name, identifier,
            request.auth.subject)
          return jsonResponse(%*{"applied": mutations.get().len})
        except CatchableError:
          ## Do not leak storage details; the atomic store has already rolled
          ## back its work before surfacing this failed formset.
          return textResponse("Inline formset was not applied", Http400)
      )
  app.get(current.prefix & "/:id", "admin." & current.name & ".get",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      if not adminAuthorized(current, request, "read",
          request.pathParams.getOrDefault("id")):
        return forbiddenResponse()
      let identifier = request.pathParams.getOrDefault("id")
      return responseVariants([
        getResponse(current.resource, identifier),
        adminDetailHtml(current, request, identifier)]))
  app.addRoute("PUT", current.prefix & "/:id",
    "admin." & current.name & ".update",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      if not adminAuthorized(current, request, "update",
          request.pathParams.getOrDefault("id")):
        return forbiddenResponse()
      let identifier = request.pathParams.getOrDefault("id")
      let response = updateResponse(current.resource, identifier,
        current.adminWritableBody(request.body))
      if response.status == Http200:
        registry.recordAudit(current.name, "update", identifier,
          request.auth.subject)
      return response)
  app.post(current.prefix & "/:id", "admin." & current.name & ".form-update",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      ## Browser forms use POST while API clients keep the explicit PUT
      ## contract above. Both paths share authorization, read-only filtering,
      ## validation, persistence, and audit semantics.
      let identifier = request.pathParams.getOrDefault("id")
      if not adminAuthorized(current, request, "update", identifier):
        return forbiddenResponse()
      let submitted = current.adminFormJson(request)
      if not submitted.valid:
        return adminFormResponse(current, request,
          current.prefix & "/" & identifier, submitted.form)
      let response = updateResponse(current.resource, identifier,
        current.adminWritableBody(submitted.body))
      if response.status == Http200:
        registry.recordAudit(current.name, "update", identifier,
          request.auth.subject)
        return adminRedirect(current.prefix)
      return response)
  app.addRoute("PATCH", current.prefix & "/:id/inline",
    "admin." & current.name & ".inline-update",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      ## Inline editors use a dedicated route so a UI can distinguish a
      ## field-level interaction from full-form replacement. The same writable
      ## body filter and update contract preserve read-only enforcement.
      let identifier = request.pathParams.getOrDefault("id")
      if not adminAuthorized(current, request, "update", identifier):
        return forbiddenResponse()
      let response = updateResponse(current.resource, identifier,
        current.adminWritableBody(request.body))
      if response.status == Http200:
        registry.recordAudit(current.name, "inline-update", identifier,
          request.auth.subject)
      return response)
  app.addRoute("DELETE", current.prefix & "/:id",
    "admin." & current.name & ".delete",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      if not adminAuthorized(current, request, "delete",
          request.pathParams.getOrDefault("id")):
        return forbiddenResponse()
      let identifier = request.pathParams.getOrDefault("id")
      let response = deleteResponse(current.resource, identifier)
      if response.status == Http204:
        registry.recordAudit(current.name, "delete", identifier,
          request.auth.subject)
      return response)
  app.post(current.prefix & "/:id/delete",
    "admin." & current.name & ".form-delete",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      ## Deletion is a distinct POST target so a browser cannot accidentally
      ## turn a detail-page refresh or ordinary form submission into a delete.
      let identifier = request.pathParams.getOrDefault("id")
      if not adminAuthorized(current, request, "delete", identifier):
        return forbiddenResponse()
      let response = deleteResponse(current.resource, identifier)
      if response.status == Http204:
        registry.recordAudit(current.name, "delete", identifier,
          request.auth.subject)
        return adminRedirect(current.prefix)
      return response)

proc registerAdminRoutes*(app: Application, registry: AdminRegistry) =
  ## Attach every explicitly registered resource to the normal application
  ## router; middleware, host policy, CSRF, and lifecycle remain in force.
  if app.isNil or registry.isNil:
    raise newException(ValueError, "Application and admin registry are required")
  for resource in registry.resources:
    registerResourceRoutes(app, registry, resource)

proc runAdminCli*(registry: AdminRegistry, arguments: openArray[string]): int =
  ## Provide a deliberately read-only CLI inspector for embedding tools and
  ## release diagnostics. It accepts a registry explicitly instead of hiding
  ## one in Application, so CLI inspection cannot bypass route authorization or
  ## invent a second persistence lifecycle.
  if registry.isNil:
    raise newException(ValueError, "Admin registry is required")
  if arguments.len != 1:
    raise newException(ValueError,
      "admin command must be exactly: resources or audit")
  case arguments[0].toLowerAscii()
  of "resources":
    for resource in registry.resources:
      echo resource.name & " " & resource.prefix
  of "audit":
    for event in registry.auditEvents():
      ## Do not print request bodies or secrets; audit events contain only the
      ## stable identity fields intentionally approved by the registry.
      echo event.resource & " " & event.action & " " & event.identifier &
        " actor=" & event.actor
  else:
    raise newException(ValueError,
      "Unknown admin command: " & arguments[0])
  0
