# Server-rendered pages

**Audience:** developers composing HTML pages with a template engine or another renderer.
**Verified with:** `nimble test`

The application owns its rendering adapter; routes own response selection.
Configure the built-in adapter before startup, then use `renderTemplateResponse`.

```nim
let app = newApplication()
let engine = newTemplateEngine()
engine.loadTemplateDirectory("templates")
app.configureTemplateAdapter(newTemplateEngineAdapter(engine))

proc home(request: Request): Future[Response] {.async, gcsafe.} =
  var context = newTemplateRenderContext()
  context.values["title"] = "Home"
  return app.renderTemplateResponse("pages/home", context)
```

`TemplateRenderContext` is per render. Put request-specific values and explicit
collections there; do not cache it across users. Another engine can use a
`CallbackTemplateAdapter` while retaining its own parser and source lifecycle.
It must preserve output escaping and the application's security responsibilities.

For progressive enhancement, render a full document and fragment through
`htmlJsonResponse`; it distinguishes `HX-Request` and `Accept` and emits `Vary`.
The framework never discovers templates automatically: configure a directory and
adapter in the composition root for deterministic tests and deployment.
