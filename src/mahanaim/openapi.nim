## Small OpenAPI projection for the explicit validation schema.
##
## The schema remains the source of truth for coercion and constraints; this
## module only publishes a machine-readable description for tooling and docs.

import std/json
import ./validation

proc fieldSchema(field: FieldSpec): JsonNode =
  result = newJObject()
  result["type"] = newJString(if field.inputType == itInteger: "integer" else: "string")
  if field.inputType == itString:
    if field.minLength >= 0: result["minLength"] = newJInt(field.minLength)
    if field.maxLength >= 0: result["maxLength"] = newJInt(field.maxLength)
  else:
    if field.minValue > low(int): result["minimum"] = newJInt(field.minValue)
    if field.maxValue < high(int): result["maximum"] = newJInt(field.maxValue)
  if field.hasDefault:
    result["default"] = newJString(field.defaultValue)

proc openApiDocument*(title, version: string,
                      schema: openArray[FieldSpec]): JsonNode =
  ## Emit an OpenAPI 3.1 document with deterministic field grouping.
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
  var body = newJObject()
  body["type"] = newJString("object")
  body["properties"] = newJObject()
  var required: seq[string] = @[]
  for field in schema:
    let property = fieldSchema(field)
    case field.location
    of flBody:
      body["properties"][field.name] = property
      if field.required: required.add(field.name)
    of flPath, flQuery, flHeader:
      let parameter = %*{
        "name": field.name,
        "in": if field.location == flPath: "path" elif field.location == flQuery: "query" else: "header",
        "required": field.required or field.location == flPath,
        "schema": property
      }
      operation["parameters"].add(parameter)
  if required.len > 0:
    body["required"] = newJArray()
    for field in required: body["required"].add(newJString(field))
  if body["properties"].len > 0:
    operation["requestBody"] = %*{
      "required": required.len > 0,
      "content": {"application/json": {"schema": body}}
    }
