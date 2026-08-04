## Compile-time model metadata generation.
##
## The macro intentionally generates only the framework-neutral metadata
## contract. SQL, migrations, serializers, and admin layers remain consumers
## of that metadata, so adding a database backend does not change this API.

import std/[macros, strutils]
import ./models
import ./validation
import ./application
import ./openapi

proc fieldName(node: NimNode): string =
  ## Exported fields appear as `Postfix(Ident, "*")` in the macro AST.
  if node.kind == nnkPostfix:
    return $node[0]
  $node

proc fieldTypeName(node: NimNode): string =
  ## Keep type mapping explicit; guessing a JSON kind would hide schema drift.
  node.repr.strip()

proc unwrapModelType(node: NimNode): tuple[base: NimNode, optional: bool,
                                            collection: bool] =
  ## `Option[T]` is the one generic type whose meaning is common to every
  ## metadata consumer: the storage value may be NULL and the input field is
  ## not required. `seq[T]` and fixed `array[N, T]` are JSON collections; the
  ## element codec remains an explicit adapter boundary instead of being
  ## guessed from arbitrary custom AST.
  result.base = node
  result.optional = false
  result.collection = false
  if node.kind == nnkBracketExpr and node.len == 2 and $node[0] == "Option":
    result.base = node[1]
    result.optional = true
  if result.base.kind == nnkBracketExpr and result.base.len >= 2 and
      $result.base[0] in ["seq", "array"]:
    result.collection = true

proc modelKind(typeNode: NimNode): NimNode =
  let typeInfo = unwrapModelType(typeNode)
  if typeInfo.collection:
    return ident("modelJson")
  let name = fieldTypeName(typeInfo.base)
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

proc metadataDeclarationName(node: NimNode): string =
  ## Declarations are intentionally limited to constructors whose result type
  ## is known by the runtime metadata contract. Rejecting arbitrary AST here
  ## prevents a macro from silently accepting an expression it cannot inspect.
  if node.kind != nnkCall or node.len == 0:
    error("Model metadata declarations must call a supported constructor", node)
  result = $node[0]
  if result notin ["newModelIndex", "newModelConstraint", "newModelRelation",
                   "newModelCustomField"]:
    error("Unsupported model metadata declaration: " & result, node)

proc customDeclarationFieldName(node: NimNode): string =
  ## A custom declaration must identify its model field with a literal name.
  ## This lets the macro detect typos before runtime metadata is consumed.
  if node.len < 3 or node[1].kind != nnkStrLit:
    error("Custom model field declaration requires a literal field name and wire type", node)
  result = node[1].strVal
  if result.strip().len == 0:
    error("Custom model field declaration requires a non-empty field name", node)

macro modelMetadata*(modelType: typedesc,
                     modelName: static[string] = "",
                     tableName: static[string] = "",
                     declarations: varargs[untyped]): untyped =
  ## Generate deterministic metadata in source field order.
  let typeNode = if modelType.kind == nnkBracketExpr: modelType[1] else: modelType
  let typeDesc = getTypeInst(modelType)
  let objectType = getImpl(typeDesc[1])
  let fields = recordFields(objectType)
  var customDeclarations: seq[(string, NimNode)] = @[]
  for declaration in declarations:
    if metadataDeclarationName(declaration) == "newModelCustomField":
      let customName = customDeclarationFieldName(declaration)
      for (existingName, _) in customDeclarations:
        if existingName == customName:
          error("Duplicate custom model field declaration: " & customName,
            declaration)
      customDeclarations.add((customName, declaration))
  let resolvedName = if modelName.len > 0: modelName else: $typeNode
  let resolvedTable = if tableName.len > 0: tableName else: resolvedName
  let generated = genSym(nskVar, "metadata")
  result = newStmtList()
  result.add quote do:
    var `generated` = newModelMetadata(`resolvedName`, `resolvedTable`)
  var matchedCustomFields: seq[string] = @[]
  for (name, typeNode) in fields:
    let fieldLiteral = newLit(name)
    var customDeclaration: NimNode = nil
    for (customName, declaration) in customDeclarations:
      if customName == name:
        customDeclaration = declaration
        matchedCustomFields.add(name)
    if not customDeclaration.isNil:
      result.add quote do:
        `generated`.addField(`customDeclaration`)
    else:
      let kindNode = modelKind(typeNode)
      let typeInfo = unwrapModelType(typeNode)
      let optionalLiteral = newLit(typeInfo.optional)
      let collectionLiteral = newLit(typeInfo.collection)
      result.add quote do:
        `generated`.addField(newModelField(`fieldLiteral`, `kindNode`,
          nullable = `optionalLiteral`, collection = `collectionLiteral`))
  for declaration in declarations:
    case metadataDeclarationName(declaration)
    of "newModelIndex":
      result.add quote do:
        `generated`.addIndex(`declaration`)
    of "newModelConstraint":
      result.add quote do:
        `generated`.addConstraint(`declaration`)
    of "newModelRelation":
      result.add quote do:
        `generated`.addRelation(`declaration`)
    of "newModelCustomField":
      discard
    else:
      discard
  for (customName, declaration) in customDeclarations:
    if customName notin matchedCustomFields:
      error("Custom model field is not declared by the model object: " &
        customName, declaration)
  result.add generated

proc inputFieldConstructor(typeNode: NimNode): NimNode =
  ## Scalars and JSON collections have safe common HTTP representations;
  ## nested DTOs and custom types stay explicit schema boundaries instead of
  ## being guessed at compile time.
  let typeInfo = unwrapModelType(typeNode)
  if typeInfo.collection:
    return ident("jsonField")
  let name = fieldTypeName(typeInfo.base)
  case name
  of "string": ident("stringField")
  of "int", "int8", "int16", "int32", "int64",
     "uint", "uint8", "uint16", "uint32", "uint64": ident("integerField")
  of "float", "float32", "float64": ident("floatField")
  of "bool": ident("booleanField")
  of "JsonNode": ident("jsonField")
  else: error("Unsupported input schema field type: " & name, typeNode)

proc generateScalarSchema(modelType, location: NimNode,
                          symbolName: string): NimNode =
  ## Shared generator keeps input and response DTO schemas semantically
  ## aligned while exposing separate macro names at the public API boundary.
  let typeDesc = getTypeInst(modelType)
  let objectType = getImpl(typeDesc[1])
  let fields = recordFields(objectType)
  let generated = genSym(nskVar, symbolName)
  result = newStmtList()
  result.add quote do:
    var `generated`: seq[FieldSpec] = @[]
  for (name, typeNode) in fields:
    let fieldLiteral = newLit(name)
    let constructor = inputFieldConstructor(typeNode)
    let requiredLiteral = newLit(not unwrapModelType(typeNode).optional)
    result.add quote do:
      `generated`.add(`constructor`(`fieldLiteral`, `location`,
        required = `requiredLiteral`))
  result.add generated

macro inputSchema*(modelType: typedesc,
                   location: static[FieldLocation] = flBody): untyped =
  ## Generate deterministic request FieldSpec values in source order.
  generateScalarSchema(modelType, newLit(location), "inputSchema")

macro responseSchema*(modelType: typedesc,
                      location: static[FieldLocation] = flBody): untyped =
  ## Generate response projection fields from the same scalar type boundary.
  ## Response schemas remain FieldSpec values so OpenAPI and serializers can
  ## consume them without introducing a second schema representation.
  generateScalarSchema(modelType, newLit(location), "responseSchema")

macro addTypedDocumentedRoute*(app, registry, operation, requestType,
                               responseType, handler: typed): untyped =
  ## Handler values are intentionally type-erased at the core boundary, so a
  ## macro cannot safely recover DTO types from a generic closure at runtime.
  ## This explicit typed declaration keeps the ergonomic one-line route API
  ## while generating request/response FieldSpec values at the call site.
  let resolved = genSym(nskVar, "typedOperation")
  result = quote do:
    block:
      var `resolved` = `operation`
      `resolved`.requestSchema = `resolved`.requestSchema &
        inputSchema(`requestType`)
      if `resolved`.responseSchema.len == 0:
        `resolved`.responseSchema = responseSchema(`responseType`)
      `app`.addDocumentedRoute(`registry`, `resolved`, `handler`)
