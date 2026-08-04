## Backend-neutral HTML form binding.
##
## Validation remains owned by `FieldSpec`/`validate`; this module maps the
## result to a renderable form context and escapes every user-controlled value.
## A future template engine can consume FormState without changing binding.

import std/[options, strutils]
import ./core
import ./security
import ./validation

type
  FormFieldState* = object
    name*: string
    label*: string
    value*: string
    inputType*: InputType
    required*: bool
    errors*: seq[string]

  FormState* = object
    fields*: seq[FormFieldState]
    errors*: seq[ValidationIssue]

proc humanLabel(name: string): string =
  ## Convert snake_case field names to a stable default label.
  for index, character in name:
    if index == 0:
      result.add(character.toUpperAscii())
    elif character == '_':
      result.add(' ')
    else:
      result.add(character)

proc bindForm*(request: Request, schema: openArray[FieldSpec]): FormState =
  ## Bind and validate in one deterministic pass; no form-specific parser exists.
  let validation = request.validate(schema)
  result.errors = validation.errors
  for field in schema:
    var state = FormFieldState(name: field.name, label: humanLabel(field.name),
      inputType: field.inputType, required: field.required, value: "", errors: @[])
    let value = validation.stringValue(field.name)
    if value.isSome:
      state.value = value.get()
    for issue in validation.errors:
      if issue.field == field.name:
        state.errors.add(issue.message)
    result.fields.add(state)

proc escapeHtml(value: string): string =
  ## `htmlgen` is not used for attributes because explicit escaping is easier to
  ## audit and remains independent from a chosen rendering engine.
  result = value
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")
  result = result.replace("'", "&#39;")

proc csrfHiddenInput*(policy: SecurityPolicy): string =
  ## Forms can opt into the same signed CSRF primitive as API middleware.
  if not policy.csrfEnabled:
    return ""
  let token = escapeHtml(csrfToken(policy))
  "<input type=\"hidden\" name=\"" & escapeHtml(policy.csrfHeaderName) &
    "\" value=\"" & token & "\">"

proc renderForm*(form: FormState, action = "", httpMethod = "post",
                 csrfPolicy: SecurityPolicy = defaultSecurityPolicy()): string =
  ## Render only a deliberately small HTML vocabulary; templates can wrap it or
  ## replace the renderer while retaining the same FormState contract.
  result = "<form action=\"" & escapeHtml(action) & "\" method=\"" &
    escapeHtml(httpMethod.toLowerAscii()) & "\">"
  result.add(csrfHiddenInput(csrfPolicy))
  for field in form.fields:
    let inputType = case field.inputType
      of itInteger, itFloat: "number"
      of itBoolean: "checkbox"
      of itJson: "textarea"
      of itString: "text"
    result.add("<label for=\"" & escapeHtml(field.name) & "\">" &
      escapeHtml(field.label) & "</label>")
    result.add("<input id=\"" & escapeHtml(field.name) & "\" name=\"" &
      escapeHtml(field.name) & "\" type=\"" & inputType & "\" value=\"" &
      escapeHtml(field.value) & "\"")
    if field.required:
      result.add(" required")
    result.add(">")
    for error in field.errors:
      result.add("<div class=\"form-error\">" & escapeHtml(error) & "</div>")
  result.add("<button type=\"submit\">Submit</button></form>")
