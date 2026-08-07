# Core application API

**Source:** `src/mahanaim/core.nim`, `application.nim`, `router.nim`.
**Verification:** `nimble publicApiCheck`, `nimble docsExamples`, `nimble test`.

## `newApplication`

Creates an isolated `Application` from config, security, and execution policies.
The caller owns all route/module/plugin registration and must complete it before
`startup`; late registration raises `ValueError`.

```nim
let app = newApplication()
app.get("/health", "health", healthHandler)
```

## `get`, `post`, `addRoute`, and `websocket`

Register an async HTTP handler or WebSocket session handler. A route name is
unique and `addRoute` accepts non-GET/POST methods. Path grammar, middleware
order, error handling, and URL generation are documented in [routing](../routing.md).
Duplicate names or post-startup registration raise `ValueError`.

## `Request` and `Response`

`Request` is an adapter-neutral input snapshot with path/query/header/cookie/body
data and `pathParams`. `Response` carries status, headers, body, representation,
and optional negotiated variants. Use `textResponse`, `htmlResponse`,
`jsonResponse`, `fileResponse`, `streamResponse`, or `sseResponse` rather than
constructing unsafe content metadata manually. See [responses](../responses-and-negotiation.md).

## `FieldSpec` and `validate`

Declare input fields with `stringField`, `integerField`, `floatField`,
`booleanField`, or `jsonField`, then call `request.validate`. It returns every
issue and `validationResponse` renders a standard problem response. See
[requests and validation](../requests-and-validation.md).
