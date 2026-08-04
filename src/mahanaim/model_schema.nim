## Shared model-to-input schema bridge.
##
## ModelMetadata is the framework reflection source of truth. This module only
## translates that declaration into the existing validation contract; it does
## not perform validation or rendering itself. That keeps model metadata,
## request validation, HTML forms, and OpenAPI projections aligned without
## coupling any of those consumers to database adapters.

import std/[json, options, strutils, tables]
import ./core
import ./application
import ./models
import ./validation
import ./forms
import ./openapi

proc inputTypeFor(kind: ModelValueKind): InputType =
  ## Map every scalar model kind to a validation representation. References,
  ## dates, and UUIDs intentionally remain strings at the HTTP boundary.
  case kind
  of modelString, modelDateTime, modelUuid, modelFile, modelReference:
    itString
  of modelInteger:
    itInteger
  of modelFloat:
    itFloat
  of modelBoolean:
    itBoolean
  of modelJson:
    itJson

proc modelFieldSpec*(field: ModelField, location = flBody,
                     required = true): FieldSpec =
  ## Nullable metadata changes the default requiredness, while an explicit
  ## caller choice still wins for PATCH or optional query schemas.
  result = FieldSpec(name: field.name, location: location,
    inputType: inputTypeFor(field.kind), required: required and not field.nullable,
    hasDefault: false, defaultValue: "", minLength: -1,
    maxLength: if field.maxLength > 0: field.maxLength else: -1,
    minValue: low(int), maxValue: high(int), enumValues: field.enumValues)

proc modelInputSchema*(metadata: ModelMetadata,
                       location = flBody,
                       includePrimaryKey = true): seq[FieldSpec] =
  ## Preserve metadata declaration order so forms and generated documents are
  ## deterministic. Primary keys can be omitted for create forms explicitly.
  for field in metadata.fields:
    if includePrimaryKey or not field.primaryKey:
      result.add(modelFieldSpec(field, location, required = true))

proc bindModelForm*(request: Request, metadata: ModelMetadata,
                    includePrimaryKey = false): FormState =
  ## Forms consume the same generated FieldSpec sequence as API validation;
  ## this wrapper prevents application code from rebuilding a second schema.
  let schema = modelInputSchema(metadata, flBody, includePrimaryKey)
  bindForm(request, schema)

proc bindModelFormSet*(requests: openArray[Request], metadata: ModelMetadata,
                       includePrimaryKey = false): FormSetState =
  ## Model formsets reuse the metadata-derived schema row by row, preserving a
  ## single source of truth for validation, forms, and API projections.
  let schema = modelInputSchema(metadata, flBody, includePrimaryKey)
  bindFormSet(requests, schema)

proc modelOpenApiDocument*(title, version: string,
                           metadata: ModelMetadata,
                           includePrimaryKey = true): JsonNode =
  ## OpenAPI is another projection of the same metadata-derived schema. The
  ## response uses the full model by default while callers can project a
  ## create/update shape by excluding primary keys.
  let schema = modelInputSchema(metadata, flBody, includePrimaryKey)
  openApiDocument(title, version, schema, schema)

proc addModelDocumentedRoute*(app: Application, registry: OpenApiRegistry,
                              operation: OpenApiOperation,
                              metadata: ModelMetadata, handler: Handler,
                              includePrimaryKey = false,
                              middleware: seq[Middleware] = @[]) =
  ## Couple a model metadata declaration to route registration without making
  ## handlers reflective. Explicit path/query/header fields remain intact;
  ## metadata contributes the body request schema and the response schema,
  ## keeping validation, forms, serializers, and OpenAPI on one source.
  if metadata.fields.len == 0:
    raise newException(ValueError, "Documented model requires at least one field")
  var resolved = operation
  let bodySchema = modelInputSchema(metadata, flBody, includePrimaryKey)
  resolved.requestSchema = operation.requestSchema & bodySchema
  if operation.responseSchema.len == 0:
    resolved.responseSchema = modelInputSchema(metadata, flBody, includePrimaryKey)
  app.addDocumentedRoute(registry, resolved, handler, middleware)

proc modelPrimitiveSchema(field: ModelField): JsonNode =
  ## Keep model-to-OpenAPI scalar mapping separate from FieldSpec mapping so
  ## JSON names, nullable fields, and nested references retain metadata that a
  ## flattened validation schema intentionally does not carry.
  result = newJObject()
  if field.collection:
    ## Collection fields are JSON arrays at the neutral boundary. A typed
    ## collection adapter may refine `items` later without changing the model
    ## metadata or the route/schema contract.
    result["type"] = newJString("array")
    result["items"] = newJObject()
  else:
    result["type"] = newJString(case field.kind
      of modelInteger: "integer"
      of modelFloat: "number"
      of modelBoolean: "boolean"
      of modelJson: "object"
      of modelString, modelDateTime, modelUuid, modelFile, modelReference: "string")
  if field.kind == modelDateTime:
    result["format"] = newJString("date-time")
  elif field.kind == modelUuid:
    result["format"] = newJString("uuid")
  if field.maxLength > 0 and result["type"].getStr() == "string":
    result["maxLength"] = newJInt(field.maxLength)
  if field.enumValues.len > 0:
    result["enum"] = newJArray()
    for value in field.enumValues:
      result["enum"].add(newJString(value))

proc modelSchemaRef*(modelName: string): JsonNode =
  ## References are generated in one place so route/document consumers cannot
  ## accidentally use a different component path for nested DTOs.
  if modelName.strip().len == 0:
    raise newException(ValueError, "Nested model name is required")
  %*{"$ref": "#/components/schemas/" & modelName}

proc addModelSchema(metadata: ModelMetadata, registry: ModelRegistry,
                    components: var JsonNode,
                    includePrimaryKey: bool): JsonNode =
  ## Register a placeholder before descending. This makes recursive DTO graphs
  ## terminate naturally and emits a stable `$ref` instead of expanding forever.
  if components.hasKey(metadata.name):
    return modelSchemaRef(metadata.name)
  components[metadata.name] = newJObject()
  let schema = %*{
    "type": "object",
    "properties": newJObject()
  }
  var required = newJArray()
  for field in metadata.fields:
    if not includePrimaryKey and field.primaryKey:
      continue
    var property: JsonNode
    if field.nestedModel.len > 0:
      let nested = registry.model(field.nestedModel)
      if nested.isNone:
        raise newException(ValueError,
          "Nested model is not registered: " & field.nestedModel)
      discard addModelSchema(nested.get(), registry, components, true)
      property = modelSchemaRef(field.nestedModel)
    else:
      property = modelPrimitiveSchema(field)
    schema["properties"][field.jsonName] = property
    if not field.nullable:
      required.add(newJString(field.jsonName))
  if required.len > 0:
    schema["required"] = required
  components[metadata.name] = schema
  modelSchemaRef(metadata.name)

proc modelOpenApiDocument*(title, version: string,
                           metadata: ModelMetadata,
                           registry: ModelRegistry,
                           includePrimaryKey = true): JsonNode =
  ## Project a registered model graph into reusable OpenAPI components. The
  ## overload preserves the original scalar API while making nested DTO
  ## documentation explicit wherever serializer graph metadata is available.
  if title.strip().len == 0 or version.strip().len == 0:
    raise newException(ValueError, "OpenAPI title and version are required")
  if not registry.models.hasKey(metadata.name):
    raise newException(ValueError,
      "Root model is not registered: " & metadata.name)
  var components = newJObject()
  let root = addModelSchema(metadata, registry, components, includePrimaryKey)
  result = %*{
    "openapi": "3.1.0",
    "info": {"title": title, "version": version},
    "paths": {"/generated": {"post": {
      "operationId": "generated",
      "responses": {"200": {"description": "Successful response"}}
    }}},
    "components": {"schemas": components}
  }
  result["paths"]["/generated"]["post"]["requestBody"] = %*{
    "required": true,
    "content": {"application/json": {"schema": root}}
  }
  result["paths"]["/generated"]["post"]["responses"]["200"]["content"] = %*{
    "application/json": {"schema": root}
  }
