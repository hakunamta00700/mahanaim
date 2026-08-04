## Metadata-driven JSON serialization.
##
## The serializer consumes only ModelMetadata and JsonNode values.  It does not
## know about a database row, HTTP adapter, or template engine, which keeps the
## reflection contract reusable across every framework boundary.

import std/[json, options, tables]
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

proc defaultSerializationPolicy*(): SerializationPolicy =
  ## Never expose sensitive fields unless a caller explicitly opts in.
  SerializationPolicy(excludeSensitive: true, includeNulls: false,
    rejectUnknownFields: false)

proc expectedKind(kind: ModelValueKind): string =
  case kind
  of modelString, modelDateTime, modelUuid, modelReference: "string"
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
                     registry: Option[ModelRegistry] = none(ModelRegistry)): SerializationResult =
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
        requireAll = requireAll, projection = @[], registry = registry)
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
    result.document[field.jsonName] = value

  if policy.rejectUnknownFields:
    for name in values.keys:
      if not metadata.hasField(name):
        result.errors.add(SerializationIssue(field: name,
          code: "unknown_field", message: "Field is not declared by model metadata"))

proc serializeModel*(metadata: ModelMetadata,
                     values: Table[string, JsonNode],
                     policy = defaultSerializationPolicy()): SerializationResult =
  ## Full document serialization keeps the original required-field contract.
  serializeValues(metadata, values, policy, requireAll = true, projection = @[])

proc serializePatch*(metadata: ModelMetadata,
                     values: Table[string, JsonNode],
                     policy = defaultSerializationPolicy()): SerializationResult =
  ## Partial updates validate only supplied fields, making it safe to merge the
  ## result into an existing record after authorization and persistence checks.
  serializeValues(metadata, values, policy, requireAll = false, projection = @[])

proc serializeModelGraph*(metadata: ModelMetadata,
                          values: Table[string, JsonNode],
                          registry: ModelRegistry,
                          policy = defaultSerializationPolicy()): SerializationResult =
  ## Serialize a DTO graph using registry-owned nested metadata. This explicit
  ## entry point prevents accidental recursive serialization when a caller only
  ## wants a flat model document.
  serializeValues(metadata, values, policy, requireAll = true, projection = @[],
    registry = some(registry))

proc serializeProjection*(metadata: ModelMetadata,
                          values: Table[string, JsonNode],
                          fields: openArray[string],
                          policy = defaultSerializationPolicy()): SerializationResult =
  ## Response projections are explicit allow-lists and preserve metadata order.
  var projection: seq[string] = @[]
  for field in fields:
    projection.add(field)
  serializeValues(metadata, values, policy, requireAll = false,
    projection = projection)

proc valid*(serialization: SerializationResult): bool =
  ## A document is usable only when all declared boundary values are valid.
  serialization.errors.len == 0

proc json*(serialization: SerializationResult): string =
  ## Keep JSON rendering at the outer boundary so callers can inspect errors
  ## before choosing an HTTP response status.
  $serialization.document
