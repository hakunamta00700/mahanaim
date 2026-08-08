# API development

**Audience:** developers publishing typed HTTP APIs.
**Status:** OpenAPI support is experimental; see [support matrix](support-matrix.md).
**Verified with:** `nimble test`

Declare an `OpenApiOperation` and install it with `addDocumentedRoute`. This keeps
runtime routing and the document registry aligned, while `FieldSpec` supplies
typed input/output metadata.

```nim
let registry = newOpenApiRegistry("Store API", "1.0.0")
let operation = OpenApiOperation(httpMethod: "GET", path: "/products/:id<int>",
  operationId: "products.get", summary: "Read one product",
  requestSchema: @[integerField("id", flPath)],
  responseSchema: @[stringField("name", flBody)])
app.addDocumentedRoute(registry, operation, getProduct)
```

Use an explicit request schema, response schema, status, and content types for
every public route. Plain `collectRoutes` can discover existing routes, but it
cannot infer a handler's body DTO. Keep filters, sort fields, pagination bounds,
and field selection allowlists in the schema/application boundary; never pass
client field names directly to storage.

Use `problemResponse` for a stable error envelope. API versioning supports URL
versions (`/v1/...`) or `Accept` `version=` negotiation through
`addVersionedDocumentedRoute`. Header version selection sets `Vary: Accept` and
`X-API-Version`; unsupported versions return 406. Mark deprecated operations and
provide a replacement before removal. Version artifact generation, compatibility
labels, deprecation period, and migration-note requirements are defined in the
[API stability policy](api-stability-policy.md).

## OpenAPI artifact 실행 예제

[`examples/api_artifacts.nim`](../examples/api_artifacts.nim)은 route를 등록한
애플리케이션에서 `openapi.json`과 `client.ts`를 생성하고, OpenAPI 3.1 버전·경로와
TypeScript client의 `ApiClient`/operation 메서드를 검증한다. 실행 명령은
`nimble docsExamples`이며 성공 시 `api-artifacts-ok`를 출력한다.
