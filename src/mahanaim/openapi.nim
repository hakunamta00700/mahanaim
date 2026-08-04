## Small OpenAPI projection for the explicit validation schema.
##
## The schema remains the source of truth for coercion and constraints; this
## module only publishes a machine-readable description for tooling and docs.

import std/json
import ./validation

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
