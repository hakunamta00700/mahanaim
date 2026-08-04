## Backend-neutral model metadata and registry.
##
## This module intentionally describes schema, not SQL or a particular database.
## Validation, serialization, forms, admin, and OpenAPI can all consume the
## same metadata while SQLite/PostgreSQL adapters remain replaceable layers.

import std/[algorithm, options, tables]

type
  ModelValueKind* = enum
    modelString
    modelInteger
    modelFloat
    modelBoolean
    modelDateTime
    modelUuid
    modelFile
    modelJson
    modelReference

  ModelRelationKind* = enum
    relationOneToOne
    relationManyToOne
    relationOneToMany
    relationManyToMany

  ModelField* = object
    ## A field is a declaration consumed by multiple framework subsystems.
    name*: string
    columnName*: string
    jsonName*: string
    kind*: ModelValueKind
    nullable*: bool
    primaryKey*: bool
    unique*: bool
    indexed*: bool
    maxLength*: int
    sensitive*: bool
    ## Optional nested DTO metadata name. Keeping this as a name instead of
    ## embedding metadata avoids recursive value objects and lets a registry
    ## remain the single source of nested schema truth.
    nestedModel*: string
    ## Optional closed value set for string-backed enum fields. Keeping enums
    ## as strings preserves backend-neutral storage while sharing one contract.
    enumValues*: seq[string]

  ModelIndex* = object
    ## Composite indexes remain backend-neutral until a migration compiler reads
    ## them, so field order is preserved explicitly.
    name*: string
    fields*: seq[string]
    unique*: bool

  ModelConstraint* = object
    ## The expression is intentionally opaque to the core; each backend can
    ## compile or reject it according to its capability matrix.
    name*: string
    expression*: string

  ModelRelation* = object
    ## Relations describe intent without embedding a database connection.
    name*: string
    kind*: ModelRelationKind
    targetModel*: string
    localField*: string
    foreignField*: string

  ModelMetadata* = object
    ## A complete model declaration suitable for registry inspection.
    name*: string
    tableName*: string
    fields*: seq[ModelField]
    indexes*: seq[ModelIndex]
    constraints*: seq[ModelConstraint]
    relations*: seq[ModelRelation]

  ModelRegistry* = object
    ## Isolated registry prevents tests or plugins from leaking model state.
    models*: Table[string, ModelMetadata]

proc newModelField*(name: string, kind: ModelValueKind,
                    columnName = "", jsonName = "", nullable = false,
                    primaryKey = false, unique = false, indexed = false,
    maxLength = 0, sensitive = false, nestedModel = ""): ModelField =
  ## Nim, database, and JSON names are independent so each adapter can use the
  ## naming convention appropriate to its boundary.
  result = ModelField(
    name: name,
    columnName: if columnName.len > 0: columnName else: name,
    jsonName: if jsonName.len > 0: jsonName else: name,
    kind: kind,
    nullable: nullable,
    primaryKey: primaryKey,
    unique: unique,
    indexed: indexed,
    maxLength: maxLength,
    sensitive: sensitive,
    nestedModel: nestedModel,
    enumValues: @[])

proc newEnumModelField*(name: string, values: openArray[string],
                       columnName = "", jsonName = "", nullable = false,
                       maxLength = 0, sensitive = false): ModelField =
  ## Enum fields remain string-backed so SQL adapters need no enum wire type.
  if values.len == 0:
    raise newException(ValueError, "Enum field requires at least one value")
  result = newModelField(name, modelString, columnName, jsonName, nullable,
    maxLength = maxLength, sensitive = sensitive)
  result.enumValues = @values

proc newModelMetadata*(name: string, tableName = ""): ModelMetadata =
  ## Keep metadata construction explicit so generated and hand-written models
  ## follow the same contract.
  result.name = name
  result.tableName = if tableName.len > 0: tableName else: name
  result.fields = @[]
  result.indexes = @[]
  result.constraints = @[]
  result.relations = @[]

proc initModelRegistry*(): ModelRegistry =
  result.models = initTable[string, ModelMetadata]()

proc field*(metadata: ModelMetadata, name: string): Option[ModelField] =
  ## Lookup is the common reflection operation used by all consumers.
  for candidate in metadata.fields:
    if candidate.name == name:
      return some(candidate)
  none(ModelField)

proc hasField*(metadata: ModelMetadata, name: string): bool =
  metadata.field(name).isSome

proc addField*(metadata: var ModelMetadata, field: ModelField) =
  ## Reject duplicate names at declaration time rather than generating
  ## ambiguous serializers or migrations later.
  if metadata.hasField(field.name):
    raise newException(ValueError, "Duplicate model field: " & field.name)
  metadata.fields.add(field)

proc addIndex*(metadata: var ModelMetadata, index: ModelIndex) =
  ## Index names are local to a model and therefore must be unique.
  for existing in metadata.indexes:
    if existing.name == index.name:
      raise newException(ValueError, "Duplicate model index: " & index.name)
  metadata.indexes.add(index)

proc addConstraint*(metadata: var ModelMetadata, constraint: ModelConstraint) =
  ## Constraint names use the same deterministic uniqueness rule as indexes.
  for existing in metadata.constraints:
    if existing.name == constraint.name:
      raise newException(ValueError, "Duplicate model constraint: " & constraint.name)
  metadata.constraints.add(constraint)

proc addRelation*(metadata: var ModelMetadata, relation: ModelRelation) =
  ## Relation names are the stable access keys exposed to serializers/forms.
  for existing in metadata.relations:
    if existing.name == relation.name:
      raise newException(ValueError, "Duplicate model relation: " & relation.name)
  metadata.relations.add(relation)

proc registerModel*(registry: var ModelRegistry, metadata: ModelMetadata) =
  ## Registration is explicit and duplicate model names are fatal.
  if registry.models.hasKey(metadata.name):
    raise newException(ValueError, "Duplicate model metadata: " & metadata.name)
  registry.models[metadata.name] = metadata

proc model*(registry: ModelRegistry, name: string): Option[ModelMetadata] =
  ## Return a copy so consumers cannot mutate the registry accidentally.
  if registry.models.hasKey(name):
    return some(registry.models[name])
  none(ModelMetadata)

proc modelNames*(registry: ModelRegistry): seq[string] =
  ## Stable ordering keeps generated documentation and tests reproducible.
  for name in registry.models.keys:
    result.add(name)
  result.sort()
