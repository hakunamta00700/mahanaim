## Compile-time model metadata generation.
##
## The macro intentionally generates only the framework-neutral metadata
## contract. SQL, migrations, serializers, and admin layers remain consumers
## of that metadata, so adding a database backend does not change this API.

import std/[macros, strutils]
import ./models
import ./validation

proc fieldName(node: NimNode): string =
  ## Exported fields appear as `Postfix(Ident, "*")` in the macro AST.
  if node.kind == nnkPostfix:
    return $node[0]
  $node

proc fieldTypeName(node: NimNode): string =
  ## Keep type mapping explicit; guessing a JSON kind would hide schema drift.
  node.repr.strip()

proc modelKind(typeNode: NimNode): NimNode =
  let name = fieldTypeName(typeNode)
  case name
  of "string": ident("modelString")
  of "int", "int8", "int16", "int32", "int64",
     "uint", "uint8", "uint16", "uint32", "uint64": ident("modelInteger")
  of "float", "float32", "float64": ident("modelFloat")
  of "bool": ident("modelBoolean")
  of "DateTime": ident("modelDateTime")
  of "UUID": ident("modelUuid")
  of "FileMetadata", "FileValue": ident("modelFile")
  of "JsonNode": ident("modelJson")
  else: error("Unsupported model field type in modelMetadata: " & name, typeNode)

proc recordFields(node: NimNode): seq[(string, NimNode)] =
  ## Walk only object record declarations. Inheritance and variant objects are
  ## rejected by the macro rather than silently producing incomplete metadata.
  case node.kind
  of nnkRecList:
    for child in node:
      result.add(recordFields(child))
  of nnkIdentDefs:
    let typeNode = node[^2]
    for index in 0 ..< node.len - 2:
      result.add((fieldName(node[index]), typeNode))
  of nnkObjectTy:
    if node[0].kind != nnkEmpty:
      error("Inherited objects are not supported by modelMetadata", node)
    result.add(recordFields(node[2]))
  of nnkTypeDef:
    ## `getTypeImpl` may retain the surrounding type definition wrapper.
    result.add(recordFields(node[^1]))
  of nnkPragmaExpr:
    result.add(recordFields(node[0]))
  of nnkEmpty:
    discard
  else:
    error("Unsupported object declaration in modelMetadata", node)

macro modelMetadata*(modelType: typedesc,
                     modelName: static[string] = "",
                     tableName: static[string] = ""): untyped =
  ## Generate deterministic metadata in source field order.
  let typeNode = if modelType.kind == nnkBracketExpr: modelType[1] else: modelType
  let typeDesc = getTypeInst(modelType)
  let objectType = getImpl(typeDesc[1])
  let fields = recordFields(objectType)
  let resolvedName = if modelName.len > 0: modelName else: $typeNode
  let resolvedTable = if tableName.len > 0: tableName else: resolvedName
  let generated = genSym(nskVar, "metadata")
  result = newStmtList()
  result.add quote do:
    var `generated` = newModelMetadata(`resolvedName`, `resolvedTable`)
  for (name, typeNode) in fields:
    let fieldLiteral = newLit(name)
    let kindNode = modelKind(typeNode)
    result.add quote do:
      `generated`.addField(newModelField(`fieldLiteral`, `kindNode`))
  result.add generated

proc inputFieldConstructor(typeNode: NimNode): NimNode =
  ## Only scalar HTTP input types are mapped automatically; nested DTOs stay
  ## an explicit schema boundary instead of being guessed at compile time.
  let name = fieldTypeName(typeNode)
  case name
  of "string": ident("stringField")
  of "int", "int8", "int16", "int32", "int64",
     "uint", "uint8", "uint16", "uint32", "uint64": ident("integerField")
  of "float", "float32", "float64": ident("floatField")
  of "bool": ident("booleanField")
  of "JsonNode": ident("jsonField")
  else: error("Unsupported input schema field type: " & name, typeNode)

macro inputSchema*(modelType: typedesc,
                   location: static[FieldLocation] = flBody): untyped =
  ## Generate deterministic FieldSpec values in source declaration order.
  let typeDesc = getTypeInst(modelType)
  let objectType = getImpl(typeDesc[1])
  let fields = recordFields(objectType)
  let generated = genSym(nskVar, "inputSchema")
  result = newStmtList()
  result.add quote do:
    var `generated`: seq[FieldSpec] = @[]
  for (name, typeNode) in fields:
    let fieldLiteral = newLit(name)
    let constructor = inputFieldConstructor(typeNode)
    result.add quote do:
      `generated`.add(`constructor`(`fieldLiteral`, `location`))
  result.add generated
