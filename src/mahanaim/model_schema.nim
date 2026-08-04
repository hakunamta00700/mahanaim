## Shared model-to-input schema bridge.
##
## ModelMetadata is the framework reflection source of truth. This module only
## translates that declaration into the existing validation contract; it does
## not perform validation or rendering itself. That keeps model metadata,
## request validation, HTML forms, and OpenAPI projections aligned without
## coupling any of those consumers to database adapters.

import std/json
import ./core
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
    minValue: low(int), maxValue: high(int))

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

proc modelOpenApiDocument*(title, version: string,
                           metadata: ModelMetadata,
                           includePrimaryKey = true): JsonNode =
  ## OpenAPI is another projection of the same metadata-derived schema. The
  ## response uses the full model by default while callers can project a
  ## create/update shape by excluding primary keys.
  let schema = modelInputSchema(metadata, flBody, includePrimaryKey)
  openApiDocument(title, version, schema, schema)
