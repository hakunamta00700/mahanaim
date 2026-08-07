# Moving from Litestar

**Audience:** Litestar developers evaluating Mahanaim.

Map route handlers to `app.get/post/addRoute`; route groups and middleware keep
the same explicit composition style. Use `FieldSpec` and model metadata instead
of signature-inferred DTO behavior, and use the application service container for
explicit dependency scopes. `OpenApiRegistry` documents typed operations while
plain route collection intentionally does not infer request/response bodies.

Background work maps to bounded queue/scheduler or durable-job registry APIs.
WebSocket/SSE, provider adapters, and OpenAPI are experimental in the support
matrix, so run their adapter/provider evidence rather than transferring a
production assumption from Litestar. See [routing](routing.md),
[API development](api-development.md), and [background jobs](background-jobs.md).
