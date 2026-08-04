## Backend-neutral HTML form binding.
##
## Validation remains owned by `FieldSpec`/`validate`; this module maps the
## result to a renderable form context and escapes every user-controlled value.
## A future template engine can consume FormState without changing binding.

import std/[options, strutils, tables]
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

  FormSetState* = object
    ## A formset is a collection of independent row forms. Request grouping is
    ## deliberately owned by the HTTP adapter, so binding remains reusable for
    ## JSON, URL-encoded, and server-rendered inputs.
    forms*: seq[FormState]
    errors*: seq[ValidationIssue]

  WidgetRenderer* = proc(field: FormFieldState): string {.gcsafe.}

  WidgetRegistry* = ref object
    ## Rendering stays behind a registry so applications can replace one
    ## field widget without forking form binding or validation contracts.
    renderers: Table[string, WidgetRenderer]

proc newWidgetRegistry*(): WidgetRegistry =
  ## A fresh registry keeps application and test customization isolated.
  new(result)
  result.renderers = initTable[string, WidgetRenderer]()

proc registerWidget*(registry: WidgetRegistry, name: string,
                     renderer: WidgetRenderer) =
  ## Duplicate names are rejected to make plugin ordering deterministic.
  if registry.isNil or name.strip().len == 0 or renderer.isNil:
    raise newException(ValueError, "Widget registry, name, and renderer are required")
  if registry.renderers.hasKey(name):
    raise newException(ValueError, "Duplicate widget: " & name)
  registry.renderers[name] = renderer

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

proc bindFormSet*(requests: openArray[Request],
                  schema: openArray[FieldSpec]): FormSetState =
  ## Bind each row through the same single-form contract; no second validator
  ## or row-specific escaping path is introduced.
  for request in requests:
    let form = bindForm(request, schema)
    result.forms.add(form)
    result.errors.add(form.errors)

proc escapeHtml(value: string): string =
  ## `htmlgen` is not used for attributes because explicit escaping is easier to
  ## audit and remains independent from a chosen rendering engine.
  result = value
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")
  result = result.replace("'", "&#39;")

proc renderWidget*(registry: WidgetRegistry, field: FormFieldState): string =
  ## Custom field widgets take precedence; the default remains compatible with
  ## the original renderer and still escapes user-controlled attributes.
  if not registry.isNil and registry.renderers.hasKey(field.name):
    return registry.renderers[field.name](field)
  let inputType = case field.inputType
    of itInteger, itFloat: "number"
    of itBoolean: "checkbox"
    of itJson: "textarea"
    of itString: "text"
  result = "<input id=\"" & escapeHtml(field.name) & "\" name=\"" &
    escapeHtml(field.name) & "\" type=\"" & inputType & "\" value=\"" &
    escapeHtml(field.value) & "\""
  if field.required:
    result.add(" required")
  result.add(">")

proc csrfHiddenInput*(policy: SecurityPolicy, token = ""): string =
  ## Forms can opt into the same signed CSRF primitive as API middleware. A
  ## request-bound token is preferred; the fallback preserves the standalone
  ## helper for callers rendering outside an HTTP request.
  if not policy.csrfEnabled:
    return ""
  let resolvedToken = if token.len > 0: token else: csrfToken(policy)
  let escapedToken = escapeHtml(resolvedToken)
  "<input type=\"hidden\" name=\"" & escapeHtml(policy.csrfHeaderName) &
    "\" value=\"" & escapedToken & "\">"

proc csrfHiddenInput*(request: Request, policy: SecurityPolicy): string =
  ## Request-aware rendering is the safe server-rendered form path because the
  ## middleware owns the token lifecycle and binds it before the handler runs.
  csrfHiddenInput(policy, request.csrfToken)

proc renderFormMarkup(form: FormState, action, httpMethod: string,
                      csrfPolicy: SecurityPolicy, token: string,
                      widgets: WidgetRegistry): string =
  ## Keep HTML assembly in one private implementation so request-aware and
  ## standalone overloads cannot drift in escaping or validation error output.
  result = "<form action=\"" & escapeHtml(action) & "\" method=\"" &
    escapeHtml(httpMethod.toLowerAscii()) & "\">"
  result.add(csrfHiddenInput(csrfPolicy, token))
  for field in form.fields:
    result.add("<label for=\"" & escapeHtml(field.name) & "\">" &
      escapeHtml(field.label) & "</label>")
    result.add(renderWidget(widgets, field))
    for error in field.errors:
      result.add("<div class=\"form-error\">" & escapeHtml(error) & "</div>")
  result.add("<button type=\"submit\">Submit</button></form>")

proc renderForm*(form: FormState, action = "", httpMethod = "post",
                 csrfPolicy: SecurityPolicy = defaultSecurityPolicy(),
                 widgets: WidgetRegistry = nil): string =
  ## Render only a deliberately small HTML vocabulary; templates can wrap it or
  ## replace the renderer while retaining the same FormState contract.
  renderFormMarkup(form, action, httpMethod, csrfPolicy, "", widgets)

proc renderForm*(form: FormState, request: Request, action = "",
                 httpMethod = "post",
                 csrfPolicy: SecurityPolicy = defaultSecurityPolicy(),
                 widgets: WidgetRegistry = nil): string =
  ## Use the token attached by securityMiddleware so the rendered form and
  ## double-submit cookie prove the same request-scoped value.
  renderFormMarkup(form, action, httpMethod, csrfPolicy, request.csrfToken,
    widgets)

proc renderFormSet*(formSet: FormSetState, action = "", httpMethod = "post",
                    csrfPolicy: SecurityPolicy = defaultSecurityPolicy(),
                    widgets: WidgetRegistry = nil): string =
  ## Render every row with one token. A formset submits against one response
  ## cookie, so generating a token per row would make all but one row invalid.
  let token = if csrfPolicy.csrfEnabled: csrfToken(csrfPolicy) else: ""
  result = "<div class=\"formset\">"
  for form in formSet.forms:
    result.add("<div class=\"formset-row\">")
    result.add(renderFormMarkup(form, action, httpMethod, csrfPolicy, token,
      widgets))
    result.add("</div>")
  result.add("</div>")

proc renderFormSet*(formSet: FormSetState, request: Request, action = "",
                    httpMethod = "post",
                    csrfPolicy: SecurityPolicy = defaultSecurityPolicy(),
                    widgets: WidgetRegistry = nil): string =
  ## Request-aware formsets share the middleware token across every row and
  ## therefore remain valid under the same double-submit cookie contract.
  result = "<div class=\"formset\">"
  for form in formSet.forms:
    result.add("<div class=\"formset-row\">")
    result.add(renderFormMarkup(form, action, httpMethod, csrfPolicy,
      request.csrfToken, widgets))
    result.add("</div>")
  result.add("</div>")
