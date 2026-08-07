# Requests and validation

**Audience:** route authors accepting query, header, path, JSON, form, or multipart input.
**Verified with:** `nimble test`

`Request` is adapter-neutral. It exposes `query`, `headers`, `cookies`, `body`,
and router-filled `pathParams`. `request.header("name")` performs the
framework's header lookup; do not assume that a transport adapter's own request
object is available in a handler.

Use `FieldSpec` declarations to make extraction, coercion, and client errors
consistent. `validate` returns every detected issue; it does not stop at the
first error.

```nim
import std/[asyncdispatch, httpcore]
import mahanaim

proc listProducts(request: Request): Future[Response] {.async, gcsafe.} =
  let input = request.validate([
    integerField("page", flQuery, required = false, defaultValue = "1", minValue = 1),
    stringField("q", flQuery, required = false, maxLength = 120),
    stringField("request-id", flHeader, required = false, maxLength = 80)
  ])
  if not input.valid:
    return input.validationResponse()
  let page = input.integerValue("page").get(1)
  return jsonResponse("{\"page\":" & $page & "}")
```

## Locations, types, and bodies

| Location | Reads from |
| --- | --- |
| `flPath` | router `pathParams` |
| `flQuery` | parsed query string |
| `flHeader` | request headers |
| `flBody` | JSON object fields, URL-encoded fields, or multipart fields |

The field constructors are `stringField`, `integerField`, `floatField`,
`booleanField`, and `jsonField`. They support required/default values and the
applicable length or numeric bounds. Boolean input accepts `true`, `false`, `1`,
and `0`. JSON accepts `application/json`, `application/*+json`, form data, and
multipart data as appropriate to its declared field.

For files or multipart metadata, call `parseRequestBody(request)` and use its
`parts`; field validation deliberately treats only non-file multipart parts as
body values. Invalid JSON or malformed multipart input becomes a body-scoped
validation issue instead of an uncaught parser exception.

## Error format

`validationResponse` returns HTTP 400 with `application/problem+json` and an
RFC 9457-style document:

```json
{"type":"about:blank","title":"Validation failed","status":400,
 "detail":"One or more input fields are invalid",
 "errors":[{"field":"page","location":"query","code":"min_value"}]}
```

Use `problemResponse` for a deliberate problem response of another status, or
`problemResponseFor` when HTML and JSON clients need negotiated error output.
Never put credentials, raw request bodies, or internal exception text in a
problem detail.
