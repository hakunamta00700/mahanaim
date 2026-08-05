## Deterministic TypeScript client projection for the explicit OpenAPI registry.
##
## The generator consumes the same registry document used by Swagger/ReDoc and
## never inspects handler closures. That keeps client generation a pure tooling
## concern while preserving the framework's explicit route/schema boundary.

import std/[json, strutils]
import ./openapi

proc tsIdentifier(value, fallback: string): string =
  ## Convert operation/module names into stable TypeScript identifiers. Invalid
  ## punctuation is folded into underscores instead of being copied into code.
  for character in value:
    if character.isAlphaNumeric() or character in {'_', '$'}:
      result.add(character)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback
  if result[0].isDigit():
    result = "_" & result
  if result in ["class", "function", "interface", "type", "const", "let",
                "var", "new", "return", "async", "await", "export"]:
    result.add("_")

proc tsPropertyName(value: string): string =
  ## Property names are quoted only when the OpenAPI field is not a normal
  ## identifier. This preserves wire names such as `user-id` exactly.
  var simple = value.len > 0
  for index, character in value:
    if not (character.isAlphaNumeric() or character in {'_', '$'}):
      simple = false
      break
  if simple and not value[0].isDigit():
    return value
  "\"" & value.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc tsLiteral(value: string): string

proc tsAccess(base, property: string): string =
  ## Use bracket access for wire names that are not valid TypeScript members.
  if property.len > 0 and
      (property[0].isAlphaNumeric() or property[0] in {'_', '$'}):
    var valid = true
    for character in property:
      if not (character.isAlphaNumeric() or character in {'_', '$'}):
        valid = false
        break
    if valid and not property[0].isDigit():
      return base & "." & property
  base & "[" & tsLiteral(property) & "]"

proc tsLiteral(value: string): string =
  ## JSON string quoting is also valid TypeScript string literal quoting.
  $(newJString(value))

proc schemaType(schema: JsonNode): string =
  if schema.isNil or schema.kind == JNull:
    return "unknown"
  if schema.hasKey("$ref"):
    let reference = schema["$ref"].getStr()
    return reference[reference.rfind('/') + 1 .. ^1]
  if schema.hasKey("oneOf") or schema.hasKey("anyOf"):
    return "unknown"
  if not schema.hasKey("type"):
    return "unknown"
  case schema["type"].getStr()
  of "string": "string"
  of "integer", "number": "number"
  of "boolean": "boolean"
  of "array":
    if schema.hasKey("items"): "Array[" & schemaType(schema["items"]) & "]"
    else: "unknown[]"
  of "object": "Record<string, unknown>"
  else: "unknown"

proc requiredProperty(schema: JsonNode, name: string): bool =
  if schema.isNil or not schema.hasKey("required"):
    return false
  for item in schema["required"].items:
    if item.getStr() == name:
      return true

proc appendInterface(output: var string, name: string, schema: JsonNode) =
  ## Inline OpenAPI object schemas become named interfaces so generated APIs
  ## remain readable and callers can reuse request/response types.
  if schema.isNil or not schema.hasKey("properties"):
    output.add("export type " & name & " = " & schemaType(schema) & ";\n\n")
    return
  output.add("export interface " & name & " {\n")
  for property, definition in schema["properties"].pairs:
    let optional = if requiredProperty(schema, property): "" else: "?"
    output.add("  " & tsPropertyName(property) & optional & ": " &
      schemaType(definition) & ";\n")
  output.add("}\n\n")

proc requestSchema(operation: JsonNode): JsonNode =
  ## Assemble path/query/header parameters and the optional JSON body into one
  ## client parameter object. The generated client therefore has one stable
  ## call shape regardless of the transport adapter used by the server.
  result = newJObject()
  result["type"] = newJString("object")
  result["properties"] = newJObject()
  result["required"] = newJArray()
  if operation.hasKey("parameters"):
    for parameter in operation["parameters"].items:
      let name = parameter["name"].getStr()
      result["properties"][name] = parameter["schema"]
      if parameter["required"].getBool():
        result["required"].add(newJString(name))
  if operation.hasKey("requestBody"):
    let contents = operation["requestBody"]["content"]
    if contents.len > 0:
      for mediaType, content in contents.pairs:
        result["properties"]["body"] = content["schema"]
        break
      result["required"].add(newJString("body"))

proc responseSchema(operation: JsonNode): JsonNode =
  ## Select the deterministic first success response. The OpenAPI document
  ## already validates operation status/content shape before this projection.
  if not operation.hasKey("responses"):
    return newJObject()
  for status, response in operation["responses"].pairs:
    if status.len > 0 and status[0] in {'2', '3'} and response.hasKey("content"):
      let contents = response["content"]
      if contents.len > 0:
        for _, content in contents.pairs:
          return content["schema"]
  newJObject()

proc typescriptClient*(registry: OpenApiRegistry,
                       clientName = "ApiClient"): string =
  ## Generate a standalone fetch-based client with no runtime dependency. The
  ## output is deterministic for a registry, making it suitable for checked-in
  ## artifacts and reproducible CI generation.
  if registry.isNil:
    raise newException(ValueError, "OpenAPI registry is required")
  let className = tsIdentifier(clientName, "ApiClient")
  let document = registry.document()
  result = "// Generated by Mahanaim. Do not edit manually.\n" &
    "export class ApiError extends Error {\n" &
    "  constructor(public readonly status: number, message: string) {\n" &
    "    super(message);\n" &
    "  }\n" &
    "}\n\n"
  var operationNames: seq[string] = @[]
  var operationTypes: seq[tuple[name: string, request: string, response: string,
                                  httpMethod: string, path: string,
                                  operation: JsonNode]] = @[]
  for operation in registry.operations:
    let normalizedMethod = operation.httpMethod.toLowerAscii()
    let operationDocument = document["paths"][operation.path][normalizedMethod]
    var baseName = tsIdentifier(operation.operationId, normalizedMethod & "Operation")
    var uniqueName = baseName
    var suffix = 2
    while uniqueName in operationNames:
      uniqueName = baseName & $suffix
      inc suffix
    operationNames.add(uniqueName)
    let requestName = uniqueName[0].toUpperAscii() & uniqueName[1 .. ^1] & "Request"
    let responseName = uniqueName[0].toUpperAscii() & uniqueName[1 .. ^1] & "Response"
    appendInterface(result, requestName, requestSchema(operationDocument))
    appendInterface(result, responseName, responseSchema(operationDocument))
    operationTypes.add((uniqueName, requestName, responseName, normalizedMethod,
      operation.path, operationDocument))
  result.add("\nexport class " & className & " {\n")
  result.add("  constructor(private readonly baseUrl = \"\", " &
    "private readonly fetchImpl: typeof fetch = fetch) {}\n\n")
  result.add("  private async request<T>(path: string, init: RequestInit): Promise<T> {\n" &
    "    const response = await this.fetchImpl(this.baseUrl + path, init);\n" &
    "    if (!response.ok) throw new ApiError(response.status, await response.text());\n" &
    "    return await response.json() as T;\n" &
    "  }\n\n")
  for item in operationTypes:
    result.add("  async " & item.name & "(params: " & item.request & "): Promise<" &
      item.response & "> {\n")
    var pathExpression = tsLiteral(item.path)
    if item.operation.hasKey("parameters"):
      for parameter in item.operation["parameters"].items:
        if parameter["in"].getStr() == "path":
          let name = parameter["name"].getStr()
          pathExpression = pathExpression.replace("{" & name & "}",
            "${encodeURIComponent(String(" & tsAccess("params", name) & "))}")
    result.add("    let path = `" & pathExpression[1 .. ^2] & "`;\n")
    var hasQuery = false
    if item.operation.hasKey("parameters"):
      for parameter in item.operation["parameters"].items:
        if parameter["in"].getStr() == "query":
          if not hasQuery:
            result.add("    const query = new URLSearchParams();\n")
            hasQuery = true
          let name = parameter["name"].getStr()
          result.add("    if (" & tsAccess("params", name) &
            " !== undefined) query.set(" & tsLiteral(name) & ", String(" &
            tsAccess("params", name) & "));\n")
    if hasQuery:
      result.add("    if (query.toString().length > 0) path += `?${query.toString()}`;\n")
    result.add("    return await this.request<" & item.response & ">(path, { method: " &
      tsLiteral(item.httpMethod.toUpperAscii()) & ", headers: {\n")
    if item.operation.hasKey("requestBody"):
      result.add("      \"content-type\": \"application/json\"\n")
    result.add("    }, body: " & (if item.operation.hasKey("requestBody"):
      "JSON.stringify(params.body)" else: "undefined") & " });\n")
    result.add("  }\n\n")
  result.add("}\n")
