## Metadata-driven JSON serialization.
##
## The serializer consumes only ModelMetadata and JsonNode values.  It does not
## know about a database row, HTTP adapter, or template engine, which keeps the
## reflection contract reusable across every framework boundary.

import std/[json, options, strutils, tables, times]
import ./models

type
  SerializationPolicy* = object
    ## Policy controls exposure without changing the model declaration.
    excludeSensitive*: bool
    includeNulls*: bool
    rejectUnknownFields*: bool

  SerializationIssue* = object
    ## Structured issues make serializer failures usable by API and form layers.
    field*: string
    code*: string
    message*: string

  SerializationResult* = object
    document*: JsonNode
    errors*: seq[SerializationIssue]

  SerializationAdapter* = ref object of RootObj
    ## Extension point for domain values that cross the JSON boundary.

  StandardSerializationAdapter* = ref object of SerializationAdapter
    ## Canonical JSON representation for framework-supported scalar values.

method encode*(adapter: SerializationAdapter, field: ModelField,
               value: JsonNode): JsonNode {.base.} =
  ## The base adapter is deliberately identity-preserving for custom fields.
  value

proc newStandardSerializationAdapter*(): StandardSerializationAdapter =
  ## Keep date, UUID, and file conventions in one reusable boundary policy.
  StandardSerializationAdapter()

proc isCanonicalUuid(value: string): bool =
  if value.len != 36:
    return false
  for index, character in value:
    if index in [8, 13, 18, 23]:
      if character != '-': return false
    elif character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc canonicalDateTime(value: string): string =
  ## The core contract starts with UTC RFC3339 seconds; adapters can support
  ## richer precision without changing ModelValueKind or serializer callers.
  let parsed = parse(value, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
  parsed.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

method encode*(adapter: StandardSerializationAdapter, field: ModelField,
               value: JsonNode): JsonNode =
  case field.kind
  of modelDateTime:
    if value.kind != JString:
      raise newException(ValueError, "DateTime must be an RFC3339 UTC string")
    newJString(canonicalDateTime(value.getStr()))
  of modelUuid:
    if value.kind != JString or not isCanonicalUuid(value.getStr()):
      raise newException(ValueError, "UUID must use canonical 36-character form")
    newJString(value.getStr().toLowerAscii())
  of modelFile:
    if value.kind != JObject or not value.hasKey("name") or
        not value.hasKey("contentType") or not value.hasKey("size"):
      raise newException(ValueError, "File metadata requires name, contentType, and size")
    if value["name"].kind != JString or value["contentType"].kind != JString or
        value["size"].kind != JInt or value["size"].getInt() < 0:
      raise newException(ValueError, "File metadata contains an invalid field")
    value
  else:
    value

proc defaultSerializationPolicy*(): SerializationPolicy =
  ## Never expose sensitive fields unless a caller explicitly opts in.
  SerializationPolicy(excludeSensitive: true, includeNulls: false,
    rejectUnknownFields: false)

proc expectedKind(kind: ModelValueKind): string =
  case kind
  of modelString, modelDateTime, modelUuid, modelReference: "string"
  of modelFile: "file metadata object"
  of modelInteger: "integer"
  of modelFloat: "number"
  of modelBoolean: "boolean"
  of modelJson: "JSON value"

proc valueMatches(field: ModelField, value: JsonNode): bool =
  ## Validate only the JSON boundary type; domain constraints stay in the
  ## validation layer so serialization remains single-purpose.
  case field.kind
  of modelString, modelDateTime, modelUuid, modelReference:
    value.kind == JString or (field.kind == modelReference and
      value.kind in {JInt, JNull})
  of modelFile:
    value.kind == JObject
  of modelInteger:
    value.kind == JInt
  of modelFloat:
    value.kind in {JInt, JFloat}
  of modelBoolean:
    value.kind == JBool
  of modelJson:
    true

proc hasField(metadata: ModelMetadata, name: string): bool =
  metadata.field(name).isSome

proc serializeValues(metadata: ModelMetadata,
                     values: Table[string, JsonNode],
                     policy: SerializationPolicy,
                     requireAll: bool,
                     projection: seq[string],
                     registry: Option[ModelRegistry] = none(ModelRegistry),
                     adapter: SerializationAdapter = nil): SerializationResult =
  ## One implementation serves full documents, patches, and projections. The
  ## caller selects whether absent fields are errors; type, null, sensitive,
  ## and unknown-field rules stay identical across every representation.
  result.document = newJObject()
  result.errors = @[]
  if projection.len > 0:
    for name in projection:
      if not metadata.hasField(name):
        result.errors.add(SerializationIssue(field: name,
          code: "unknown_projection",
          message: "Projection field is not declared by model metadata"))
  for field in metadata.fields:
    if projection.len > 0 and field.name notin projection:
      continue
    if field.sensitive and policy.excludeSensitive:
      continue
    if not values.hasKey(field.name):
      if requireAll and policy.includeNulls and field.nullable:
        result.document[field.jsonName] = newJNull()
      elif requireAll and not field.nullable:
        result.errors.add(SerializationIssue(field: field.name,
          code: "required", message: "Required model field is missing"))
      continue
    let value = values[field.name]
    if value.kind == JNull and not field.nullable:
      result.errors.add(SerializationIssue(field: field.name,
        code: "null_not_allowed", message: "Model field cannot be null"))
      continue
    if field.nestedModel.len > 0:
      if value.kind != JObject:
        result.errors.add(SerializationIssue(field: field.name,
          code: "invalid_nested_type",
          message: "Nested DTO must be a JSON object"))
        continue
      if registry.isNone or registry.get.model(field.nestedModel).isNone:
        result.errors.add(SerializationIssue(field: field.name,
          code: "nested_model_missing",
          message: "Nested model metadata is not registered"))
        continue
      let nestedMetadata = registry.get.model(field.nestedModel).get()
      var nestedValues = initTable[string, JsonNode]()
      for name, nestedValue in value:
        var resolvedName = name
        for nestedField in nestedMetadata.fields:
          if nestedField.jsonName == name or nestedField.name == name:
            resolvedName = nestedField.name
            break
        nestedValues[resolvedName] = nestedValue
      let nested = serializeValues(nestedMetadata, nestedValues, policy,
        requireAll = requireAll, projection = @[], registry = registry,
        adapter = adapter)
      for issue in nested.errors:
        result.errors.add(SerializationIssue(field: field.name & "." & issue.field,
          code: issue.code, message: issue.message))
      result.document[field.jsonName] = nested.document
      continue
    if value.kind != JNull and not valueMatches(field, value):
      result.errors.add(SerializationIssue(field: field.name,
        code: "invalid_type",
        message: "Expected " & expectedKind(field.kind)))
      continue
    try:
      result.document[field.jsonName] = if adapter.isNil: value else:
        adapter.encode(field, value)
    except CatchableError as error:
      result.errors.add(SerializationIssue(field: field.name,
        code: "adapter_error", message: error.msg))

  if policy.rejectUnknownFields:
    for name in values.keys:
      if not metadata.hasField(name):
        result.errors.add(SerializationIssue(field: name,
          code: "unknown_field", message: "Field is not declared by model metadata"))

proc serializeModel*(metadata: ModelMetadata,
                     values: Table[string, JsonNode],
                     policy = defaultSerializationPolicy(),
                     adapter: SerializationAdapter = nil): SerializationResult =
  ## Full document serialization keeps the original required-field contract.
  serializeValues(metadata, values, policy, requireAll = true, projection = @[],
    adapter = adapter)

proc serializePatch*(metadata: ModelMetadata,
                     values: Table[string, JsonNode],
                     policy = defaultSerializationPolicy(),
                     adapter: SerializationAdapter = nil): SerializationResult =
  ## Partial updates validate only supplied fields, making it safe to merge the
  ## result into an existing record after authorization and persistence checks.
  serializeValues(metadata, values, policy, requireAll = false, projection = @[],
    adapter = adapter)

proc serializeModelGraph*(metadata: ModelMetadata,
                          values: Table[string, JsonNode],
                          registry: ModelRegistry,
                          policy = defaultSerializationPolicy(),
                          adapter: SerializationAdapter = nil): SerializationResult =
  ## Serialize a DTO graph using registry-owned nested metadata. This explicit
  ## entry point prevents accidental recursive serialization when a caller only
  ## wants a flat model document.
  serializeValues(metadata, values, policy, requireAll = true, projection = @[],
    registry = some(registry), adapter = adapter)

proc serializeProjection*(metadata: ModelMetadata,
                          values: Table[string, JsonNode],
                          fields: openArray[string],
                          policy = defaultSerializationPolicy(),
                          adapter: SerializationAdapter = nil): SerializationResult =
  ## Response projections are explicit allow-lists and preserve metadata order.
  var projection: seq[string] = @[]
  for field in fields:
    projection.add(field)
  serializeValues(metadata, values, policy, requireAll = false,
    projection = projection, adapter = adapter)

proc valid*(serialization: SerializationResult): bool =
  ## A document is usable only when all declared boundary values are valid.
  serialization.errors.len == 0

proc json*(serialization: SerializationResult): string =
  ## Keep JSON rendering at the outer boundary so callers can inspect errors
  ## before choosing an HTTP response status.
  $serialization.document
