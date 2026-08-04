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

proc serializeModel*(metadata: ModelMetadata,
                     values: Table[string, JsonNode],
                     policy = defaultSerializationPolicy()): SerializationResult =
  ## Serialize declared fields in metadata order for deterministic output.
  result.document = newJObject()
  result.errors = @[]
  for field in metadata.fields:
    if field.sensitive and policy.excludeSensitive:
      continue
    if not values.hasKey(field.name):
      if policy.includeNulls and field.nullable:
        result.document[field.jsonName] = newJNull()
      elif not field.nullable:
        result.errors.add(SerializationIssue(field: field.name,
          code: "required", message: "Required model field is missing"))
      continue
    let value = values[field.name]
    if value.kind == JNull and not field.nullable:
      result.errors.add(SerializationIssue(field: field.name,
        code: "null_not_allowed", message: "Model field cannot be null"))
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

proc valid*(serialization: SerializationResult): bool =
  ## A document is usable only when all declared boundary values are valid.
  serialization.errors.len == 0

proc json*(serialization: SerializationResult): string =
  ## Keep JSON rendering at the outer boundary so callers can inspect errors
  ## before choosing an HTTP response status.
  $serialization.document
