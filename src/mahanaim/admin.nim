## Metadata-driven admin registry.
##
## This first admin slice deliberately composes existing CRUD, form, and
## security contracts instead of introducing a second persistence or template
## system. It provides a secure registration boundary, JSON CRUD routes, an
## HTML create form, and an in-memory audit trail; richer permissions and
## layouts remain extension points.

import std/[asyncdispatch, httpcore, json, options, strutils, tables]
import ./application
import ./authorization
import ./core
import ./forms
import ./model_schema
import ./models
import ./query_components
import ./resources
import ./security
import ./validation

type
  AdminAuthorization* = proc(request: Request): bool {.gcsafe.}

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

method appendAuditEvent*(store: InMemoryAdminAuditStore,
                         event: AdminAuditEvent) {.gcsafe.} =
  store.events.add(event)

method auditEvents*(store: InMemoryAdminAuditStore): seq[AdminAuditEvent] {.gcsafe.} =
  store.events

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
                            customColumns: seq[string] = @[]) =
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
    customColumns: canonicalColumns))

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

proc adminAuthorized(resource: AdminResource, request: Request,
                     action, objectId: string): bool =
  ## The legacy callback remains a coarse application boundary; when a policy
  ## is configured, it supplies the composable role/group/object decision too.
  if not resource.authorize(request):
    return false
  resource.authorizationPolicy.isNil or resource.authorizationPolicy.allows(
    request, resource.permissionResource, action, objectId)

proc adminForm(resource: AdminResource): Response =
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
  htmlResponse(renderForm(form, action = resource.prefix,
    csrfPolicy = resource.formPolicy))

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
      return listResponse(current.resource, parsed.query))
  app.get(current.prefix & "/new", "admin." & current.name & ".form",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      if not adminAuthorized(current, request, "create", ""):
        return forbiddenResponse()
      return adminForm(current))
  app.post(current.prefix, "admin." & current.name & ".create",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      if not adminAuthorized(current, request, "create", ""):
        return forbiddenResponse()
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
  app.get(current.prefix & "/:id", "admin." & current.name & ".get",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      if not adminAuthorized(current, request, "read",
          request.pathParams.getOrDefault("id")):
        return forbiddenResponse()
      return getResponse(current.resource, request.pathParams.getOrDefault("id")))
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

proc registerAdminRoutes*(app: Application, registry: AdminRegistry) =
  ## Attach every explicitly registered resource to the normal application
  ## router; middleware, host policy, CSRF, and lifecycle remain in force.
  if app.isNil or registry.isNil:
    raise newException(ValueError, "Application and admin registry are required")
  for resource in registry.resources:
    registerResourceRoutes(app, registry, resource)
