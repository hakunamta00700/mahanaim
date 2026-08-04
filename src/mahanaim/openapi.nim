## Small OpenAPI projection for the explicit validation schema.
##
## The schema remains the source of truth for coercion and constraints; this
## module only publishes a machine-readable description for tooling and docs.

import std/[asyncdispatch, json, strutils]
import ./application
import ./core
import ./router
import ./validation

type
  OpenApiOperation* = object
    ## A route declaration is data first, so adapters and documentation tools
    ## can inspect it without executing request handlers.
    httpMethod*: string
    path*: string
    operationId*: string
    summary*: string
    requestSchema*: seq[FieldSpec]
    responseSchema*: seq[FieldSpec]
    ## A route may advertise more than JSON while sharing the same validated
    ## schema. Empty lists retain the historical JSON default.
    requestContentTypes*: seq[string]
    responseContentTypes*: seq[string]
    successStatus*: int

  OpenApiRegistry* = ref object
    ## The registry owns only OpenAPI declarations; Application owns route
    ## registration and lifecycle, keeping documentation independently testable.
    title*: string
    version*: string
    operations*: seq[OpenApiOperation]

proc newOpenApiRegistry*(title, version: string): OpenApiRegistry =
  ## Require stable identity metadata so generated documents are publishable.
  if title.strip().len == 0 or version.strip().len == 0:
    raise newException(ValueError, "OpenAPI title and version are required")
  new(result)
  result.title = title
  result.version = version
  result.operations = @[]

proc normalizeHttpMethod(httpMethod: string): string =
  result = httpMethod.toLowerAscii()
  if result notin ["get", "post", "put", "patch", "delete", "head", "options"]:
    raise newException(ValueError, "Unsupported OpenAPI HTTP method: " & httpMethod)

proc normalizeContentTypes(values: openArray[string]): seq[string] =
  ## Content types are exact media-type keys in an OpenAPI content map. Reject
  ## parameters and whitespace here so generated documents never contain an
  ## ambiguous key such as `application/json; charset=utf-8`.
  for raw in values:
    let value = raw.strip().toLowerAscii()
    let separator = value.find('/')
    var containsWhitespace = false
    for character in value:
      if character in {' ', '\t', '\r', '\n'}:
        containsWhitespace = true
        break
    if separator <= 0 or separator == value.high or containsWhitespace:
      raise newException(ValueError, "Invalid OpenAPI content type: " & raw)
    if value notin result:
      result.add(value)

proc contentTypes(values: seq[string], fallback: string): seq[string] =
  if values.len == 0:
    return @[fallback]
  values

proc registerOperation*(registry: OpenApiRegistry,
                        operation: OpenApiOperation) =
  ## Duplicate method/path pairs are rejected to prevent silently stale docs.
  if registry.isNil or operation.path.len == 0 or operation.path[0] != '/':
    raise newException(ValueError, "OpenAPI operation path must start with '/'")
  let normalizedMethod = normalizeHttpMethod(operation.httpMethod)
  if operation.operationId.strip().len == 0:
    raise newException(ValueError, "OpenAPI operationId is required")
  for existing in registry.operations:
    if normalizeHttpMethod(existing.httpMethod) == normalizedMethod and
       existing.path == operation.path:
      raise newException(ValueError,
        "Duplicate OpenAPI operation: " & normalizedMethod & " " & operation.path)
  var normalized = operation
  normalized.httpMethod = normalizedMethod
  normalized.requestContentTypes = normalizeContentTypes(
    operation.requestContentTypes)
  normalized.responseContentTypes = normalizeContentTypes(
    operation.responseContentTypes)
  normalized.successStatus = if operation.successStatus > 0:
    operation.successStatus else: 200
  registry.operations.add(normalized)

proc hasOperation(registry: OpenApiRegistry, httpMethod, path: string): bool =
  ## Explicit declarations win over generated fallback metadata. This helper
  ## keeps collection idempotent when a host calls it after plugin discovery.
  for operation in registry.operations:
    if normalizeHttpMethod(operation.httpMethod) == httpMethod.toLowerAscii() and
       operation.path == path:
      return true
  false

proc generatedOperationId(route: Route): string =
  ## Nameless routes still need a stable OpenAPI operationId. The route name is
  ## preferred, while this deterministic fallback keeps collection useful for
  ## low-level applications that intentionally omit names.
  if route.name.strip().len > 0:
    return route.name
  var suffix = route.pattern.replace("/", ".")
  suffix = suffix.replace(":", "param.")
  suffix = suffix.replace("*", "wildcard.")
  route.httpMethod.toLowerAscii() & suffix

proc routeOpenApiMetadata(route: Route): (string, seq[FieldSpec]) =
  ## Translate the router's `:id<int>`/`*path` grammar into OpenAPI's
  ## `{id}` path syntax and retain the router's scalar constraint as a typed
  ## path FieldSpec. This keeps generated docs useful without reflecting into
  ## handler closures or guessing request body schemas.
  var pathSegments: seq[string] = @[]
  var parameters: seq[FieldSpec] = @[]
  for segment in route.pattern.split('/'):
    if segment.len == 0:
      continue
    if segment[0] != ':' and segment[0] != '*':
      pathSegments.add(segment)
      continue
    if segment.len < 2:
      pathSegments.add(segment)
      continue
    let raw = segment[1 .. ^1]
    let typeStart = raw.find('<')
    let name = if typeStart < 0: raw else: raw[0 ..< typeStart]
    let kind = if typeStart < 0 or not raw.endsWith(">"):
      "" else: raw[typeStart + 1 ..< raw.len - 1].toLowerAscii()
    if name.len == 0:
      pathSegments.add(segment)
      continue
    pathSegments.add("{" & name & "}")
    case kind
    of "int", "uint": parameters.add(integerField(name, flPath))
    of "float": parameters.add(floatField(name, flPath))
    of "bool": parameters.add(booleanField(name, flPath))
    else: parameters.add(stringField(name, flPath))
  let path = if pathSegments.len == 0: "/" else: "/" & pathSegments.join("/")
  (path, parameters)

proc collectRoutes*(registry: OpenApiRegistry, router: Router): int =
  ## Discover plain HTTP routes after application/plugin registration. The
  ## collector emits operation metadata with empty schemas; callers can still
  ## use addDocumentedRoute for typed declarations, and those declarations are
  ## preserved when collection runs later. WebSocket routes stay out of the
  ## HTTP OpenAPI document because their handshake is a separate contract.
  if registry.isNil:
    raise newException(ValueError, "OpenAPI registry is required")
  for route in router.routes:
    let routeMethod = route.httpMethod.toLowerAscii()
    let (path, requestSchema) = routeOpenApiMetadata(route)
    if registry.hasOperation(routeMethod, path):
      continue
    registry.registerOperation(OpenApiOperation(
      httpMethod: routeMethod,
      path: path,
      operationId: generatedOperationId(route),
      summary: "",
      requestSchema: requestSchema,
      responseSchema: @[],
      successStatus: 200))
    inc result

proc addDocumentedRoute*(app: Application, registry: OpenApiRegistry,
                         operation: OpenApiOperation, handler: Handler,
                         middleware: seq[Middleware] = @[]) =
  ## Couple route registration and OpenAPI registration at one declaration
  ## boundary. The rollback keeps the two registries consistent if the router
  ## rejects a duplicate route or malformed handler registration.
  if app.isNil or registry.isNil or handler.isNil:
    raise newException(ValueError,
      "Application, OpenAPI registry, and route handler are required")
  let operationCount = registry.operations.len
  registry.registerOperation(operation)
  try:
    app.addRoute(operation.httpMethod, operation.path,
      operation.operationId, handler, middleware)
  except CatchableError:
    registry.operations.setLen(operationCount)
    raise

proc fieldSchema(field: FieldSpec): JsonNode =
  result = newJObject()
  result["type"] = newJString(case field.inputType
    of itString: "string"
    of itInteger: "integer"
    of itFloat: "number"
    of itBoolean: "boolean"
    of itJson: "object")
  if field.inputType == itString:
    if field.minLength >= 0: result["minLength"] = newJInt(field.minLength)
    if field.maxLength >= 0: result["maxLength"] = newJInt(field.maxLength)
    if field.enumValues.len > 0:
      result["enum"] = newJArray()
      for value in field.enumValues:
        result["enum"].add(newJString(value))
  else:
    if field.minValue > low(int): result["minimum"] = newJInt(field.minValue)
    if field.maxValue < high(int): result["maximum"] = newJInt(field.maxValue)
  if field.hasDefault:
    result["default"] = newJString(field.defaultValue)

proc objectSchema*(schema: openArray[FieldSpec]): JsonNode =
  ## Project body fields into a reusable object schema for both input and
  ## output DTOs. Keeping this helper shared prevents request/response drift.
  result = newJObject()
  result["type"] = newJString("object")
  result["properties"] = newJObject()
  var required: seq[string] = @[]
  for field in schema:
    if field.location != flBody:
      raise newException(ValueError,
        "Object schema fields must use the body location")
    result["properties"][field.name] = fieldSchema(field)
    if field.required:
      required.add(field.name)
  if required.len > 0:
    result["required"] = newJArray()
    for field in required:
      result["required"].add(newJString(field))

proc operationDocument(operation: OpenApiOperation): JsonNode =
  ## Build one OpenAPI operation while preserving the existing FieldSpec
  ## projection rules for parameters, request bodies, and responses.
  result = newJObject()
  result["operationId"] = newJString(operation.operationId)
  if operation.summary.strip().len > 0:
    result["summary"] = newJString(operation.summary)
  result["parameters"] = newJArray()
  var bodyFields: seq[FieldSpec] = @[]
  for field in operation.requestSchema:
    let property = fieldSchema(field)
    case field.location
    of flBody:
      bodyFields.add(field)
    of flPath, flQuery, flHeader:
      result["parameters"].add(%*{
        "name": field.name,
        "in": if field.location == flPath: "path" elif field.location == flQuery: "query" else: "header",
        "required": field.required or field.location == flPath,
        "schema": property
      })
  let body = objectSchema(bodyFields)
  if body["properties"].len > 0:
    let content = newJObject()
    for mediaType in contentTypes(operation.requestContentTypes,
                                   "application/json"):
      content[mediaType] = %*{"schema": body}
    result["requestBody"] = %*{
      "required": body.hasKey("required"), "content": content}
  let status = $operation.successStatus
  result["responses"] = newJObject()
  result["responses"][status] = %*{"description": "Successful response"}
  if operation.responseSchema.len > 0:
    let responseObject = objectSchema(operation.responseSchema)
    let content = newJObject()
    for mediaType in contentTypes(operation.responseContentTypes,
                                   "application/json"):
      content[mediaType] = %*{"schema": responseObject}
    result["responses"][status]["content"] = content

proc document*(registry: OpenApiRegistry): JsonNode =
  ## Generate a deterministic multi-route OpenAPI 3.1 document.
  if registry.isNil:
    raise newException(ValueError, "OpenAPI registry is required")
  result = %*{
    "openapi": "3.1.0",
    "info": {"title": registry.title, "version": registry.version},
    "paths": newJObject()
  }
  for operation in registry.operations:
    if not result["paths"].hasKey(operation.path):
      result["paths"][operation.path] = newJObject()
    result["paths"][operation.path][normalizeHttpMethod(operation.httpMethod)] =
      operationDocument(operation)

proc htmlAttribute(value: string): string =
  ## UI URLs are inserted into HTML attributes, so escape them independently
  ## from the JSON document serialization path.
  result = value.replace("&", "&amp;")
  result = result.replace("\"", "&quot;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")

proc swaggerUiHtml*(specUrl = "/openapi.json"): string =
  ## Keep the UI shell dependency-free at the framework boundary; the browser
  ## loads the well-known Swagger UI bundle and the registry JSON URL.
  let jsonUrl = $(newJString(specUrl))
  "<!doctype html><html><head><title>API docs</title>" &
    "<link rel=\"stylesheet\" href=\"https://unpkg.com/swagger-ui-dist/swagger-ui.css\"></head>" &
    "<body><div id=\"swagger-ui\"></div>" &
    "<script src=\"https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js\"></script>" &
    "<script>window.ui=SwaggerUIBundle({url:" & jsonUrl &
    ",dom_id:'#swagger-ui'});</script></body></html>"

proc redocHtml*(specUrl = "/openapi.json"): string =
  ## ReDoc uses the same registry endpoint, giving deployments a second UI
  ## without duplicating route/schema declarations.
  "<!doctype html><html><head><title>API reference</title></head><body>" &
    "<redoc spec-url=\"" & htmlAttribute(specUrl) & "\"></redoc>" &
    "<script src=\"https://unpkg.com/redoc/bundles/redoc.standalone.js\"></script>" &
    "</body></html>"

proc registerOpenApiRoutes*(app: Application, registry: OpenApiRegistry,
                            jsonPath = "/openapi.json",
                            swaggerPath = "/docs",
                            redocPath = "/redoc") =
  ## Register documentation endpoints through normal Application routing so
  ## middleware, host policy, and lifecycle checks remain applicable.
  if app.isNil or registry.isNil:
    raise newException(ValueError, "Application and OpenAPI registry are required")
  if jsonPath.len == 0 or swaggerPath.len == 0 or redocPath.len == 0:
    raise newException(ValueError, "OpenAPI routes require non-empty paths")
  app.get(jsonPath, "openapi.document",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      discard request
      return jsonResponse(registry.document()))
  app.get(swaggerPath, "openapi.swagger-ui",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      discard request
      return htmlResponse(swaggerUiHtml(jsonPath)))
  app.get(redocPath, "openapi.redoc",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      discard request
      return htmlResponse(redocHtml(jsonPath)))

proc openApiDocument*(title, version: string,
                      schema: openArray[FieldSpec],
                      responseSchema: openArray[FieldSpec]): JsonNode

proc openApiDocument*(title, version: string,
                      schema: openArray[FieldSpec]): JsonNode =
  ## Backward-compatible input-only document overload.
  let emptyResponse: seq[FieldSpec] = @[]
  openApiDocument(title, version, schema, emptyResponse)

proc openApiDocument*(title, version: string,
                      schema: openArray[FieldSpec],
                      responseSchema: openArray[FieldSpec]): JsonNode =
  ## Emit OpenAPI 3.1 with shared explicit input and typed response schemas.
  result = %*{
    "openapi": "3.1.0",
    "info": {"title": title, "version": version},
    "paths": {"/generated": {"post": {
      "operationId": "generated",
      "responses": {"200": {"description": "Successful response"}}
    }}}
  }
  let operation = result["paths"]["/generated"]["post"]
  operation["parameters"] = newJArray()
  var bodyFields: seq[FieldSpec] = @[]
  for field in schema:
    let property = fieldSchema(field)
    case field.location
    of flBody:
      bodyFields.add(field)
    of flPath, flQuery, flHeader:
      let parameter = %*{
        "name": field.name,
        "in": if field.location == flPath: "path" elif field.location == flQuery: "query" else: "header",
        "required": field.required or field.location == flPath,
        "schema": property
      }
      operation["parameters"].add(parameter)
  let body = objectSchema(bodyFields)
  if body["properties"].len > 0:
    operation["requestBody"] = %*{
      "required": body.hasKey("required"),
      "content": {"application/json": {"schema": body}}
    }
  if responseSchema.len > 0:
    operation["responses"]["200"]["content"] = %*{
      "application/json": {"schema": objectSchema(responseSchema)}
    }
