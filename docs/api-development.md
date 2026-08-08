# API development

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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
