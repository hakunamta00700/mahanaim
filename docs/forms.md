# Forms and CSRF

**Audience:** developers rendering validated server-side forms.
**Verified with:** `nimble test`

`bindForm(request, schema)` uses the same `FieldSpec` validation as APIs and
returns `FormState` with values and per-field errors.

```nim
let schema = [stringField("email", flBody, maxLength = 254)]
let form = bindForm(request, schema)
if form.errors.len > 0:
  return htmlResponse(renderForm(form, request, action = "/signup"))
```

`renderForm` selects safe default widgets, escapes values and errors, and uses a
request-bound CSRF token when given `request`. Handwritten templates should use
`csrfHiddenInput(request, policy)` rather than minting another token. Rendering
the field does not replace CSRF validation middleware.

`bindModelForm` and `bindModelFormSet` derive schemas from `ModelMetadata`, so
forms, validation, and OpenAPI retain a single declaration. `bindFormSet` keeps
rows independent and gathers every error. A request-aware formset shares one
CSRF token across all rows.

Use `WidgetRegistry.registerWidget` to replace a field widget. The callback must
escape inserted values and must not trust raw request input. Keep business rules
in `FieldSpec` or model metadata, not the widget.
