## Explicit input schema, coercion, and structured validation errors.
##
## This is the first API validation layer. It uses a declarative schema instead
## of a macro, which keeps generated code debuggable while leaving room for a
## macro to compile the same FieldSpec values later.

import std/[httpcore, json, options, strutils, tables]
import ./core

type
  FieldLocation* = enum
    ## Locations are kept explicit so clients can render errors correctly.
    flPath, flQuery, flHeader, flBody

  InputType* = enum
    itString, itInteger

  FieldSpec* = object
    ## A single input declaration and its validation constraints.
    name*: string
    location*: FieldLocation
    inputType*: InputType
    required*: bool
    hasDefault*: bool
    defaultValue*: string
    minLength*: int
    maxLength*: int
    minValue*: int
    maxValue*: int

  ValidationIssue* = object
    ## Machine-readable issue information for forms and API clients.
    field*: string
    location*: string
    code*: string
    message*: string

  ValidationResult* = object
    values*: Table[string, string]
    errors*: seq[ValidationIssue]

proc stringField*(name: string, location: FieldLocation,
                  required = true, defaultValue = "",
                  minLength = -1, maxLength = -1): FieldSpec =
  ## Declare a string field. `defaultValue` is active when non-empty.
  result = FieldSpec(name: name, location: location, inputType: itString,
    required: required, hasDefault: defaultValue.len > 0,
    defaultValue: defaultValue, minLength: minLength, maxLength: maxLength,
    minValue: low(int), maxValue: high(int))

proc integerField*(name: string, location: FieldLocation,
                   required = true, defaultValue = "",
                   minValue = low(int), maxValue = high(int)): FieldSpec =
  ## Declare an integer field with coercion and numeric bounds.
  result = FieldSpec(name: name, location: location, inputType: itInteger,
    required: required, hasDefault: defaultValue.len > 0,
    defaultValue: defaultValue, minLength: -1, maxLength: -1,
    minValue: minValue, maxValue: maxValue)

proc locationName(location: FieldLocation): string =
  case location
  of flPath: "path"
  of flQuery: "query"
  of flHeader: "header"
  of flBody: "body"

proc addIssue(result: var ValidationResult, spec: FieldSpec,
              code, message: string) =
  ## Centralize issue creation to guarantee every error has a location.
  result.errors.add(ValidationIssue(field: spec.name,
    location: locationName(spec.location), code: code, message: message))

proc rawValue(request: Request, spec: FieldSpec): Option[string] =
  case spec.location
  of flPath:
    if request.pathParams.hasKey(spec.name): some(request.pathParams[spec.name])
    else: none(string)
  of flQuery:
    if request.query.hasKey(spec.name): some(request.query[spec.name])
    else: none(string)
  of flHeader:
    request.header(spec.name)
  of flBody:
    if request.body.len > 0: some(request.body)
    else: none(string)

proc validate*(request: Request, schema: openArray[FieldSpec]): ValidationResult =
  ## Validate all fields and return every issue instead of failing fast.
  result.values = initTable[string, string]()
  result.errors = @[]
  for spec in schema:
    var value = rawValue(request, spec)
    if value.isNone and spec.hasDefault:
      value = some(spec.defaultValue)
    if value.isNone or value.get().len == 0:
      if spec.required:
        result.addIssue(spec, "required", "This field is required")
      continue

    let raw = value.get()
    case spec.inputType
    of itString:
      if spec.minLength >= 0 and raw.len < spec.minLength:
        result.addIssue(spec, "min_length", "Value is shorter than the minimum length")
      if spec.maxLength >= 0 and raw.len > spec.maxLength:
        result.addIssue(spec, "max_length", "Value is longer than the maximum length")
    of itInteger:
      try:
        let number = parseInt(raw)
        if number < spec.minValue:
          result.addIssue(spec, "min_value", "Value is below the minimum")
        if number > spec.maxValue:
          result.addIssue(spec, "max_value", "Value is above the maximum")
      except ValueError:
        result.addIssue(spec, "invalid_integer", "Value must be an integer")
    result.values[spec.name] = raw

proc valid*(validation: ValidationResult): bool =
  ## A result is valid only when all declared fields passed validation.
  validation.errors.len == 0

proc stringValue*(validation: ValidationResult, name: string): Option[string] =
  if validation.values.hasKey(name): some(validation.values[name])
  else: none(string)

proc integerValue*(validation: ValidationResult, name: string): Option[int] =
  if not validation.values.hasKey(name):
    return none(int)
  try:
    some(parseInt(validation.values[name]))
  except ValueError:
    none(int)

proc problemResponse*(status: HttpCode, title, detail: string,
                      issues: openArray[ValidationIssue] = []): Response =
  ## Produce RFC 9457-style JSON with field-level validation details.
  var document = %*{
    "type": "about:blank",
    "title": title,
    "status": status.int,
    "detail": detail
  }
  document["errors"] = newJArray()
  for issue in issues:
    document["errors"].add(%*{
      "field": issue.field,
      "location": issue.location,
      "code": issue.code,
      "message": issue.message
    })
  result = newResponse(status, $document)
  result.headers["content-type"] = "application/problem+json"

proc validationResponse*(validation: ValidationResult): Response =
  ## Standard response for an invalid request schema.
  problemResponse(Http400, "Validation failed",
    "One or more input fields are invalid", validation.errors)
