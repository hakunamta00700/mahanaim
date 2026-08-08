# OpenAPI and generated clients

**Audience:** API maintainers publishing OpenAPI 3.1 artifacts.
**Status:** experimental.
**Verified with:** `nimble test`, `mahanaim openapi`, `mahanaim openapi-ts`

`OpenApiRegistry.document` emits OpenAPI 3.1. Register `addOpenApiRoutes` to
serve the JSON document plus Swagger UI and ReDoc endpoints. The UI assets are
external browser resources; apply your deployment CSP and network policy before
exposing them publicly.

The CLI first collects plain registered routes, then writes an artifact:

```text
mahanaim openapi openapi.json
mahanaim openapi-ts client.ts
```

Generated route collection supplies path parameter metadata but not guessed
request/response schemas. Use documented routes for public contracts. The
TypeScript client is an artifact, not an authority: review its generated types,
error handling, authentication hooks, and versioning before publishing it.

Generate the document in CI, compare it to the approved API compatibility
policy, and publish the exact revision alongside the server release. Do not hand
edit generated artifacts; change the route/schema declaration and regenerate.

로컬 artifact 생성·검증은 [`examples/api_artifacts.nim`](../examples/api_artifacts.nim)을
`nimble docsExamples`로 실행한다. 이 예제는 임시 경로의 `openapi.json`과 `client.ts`를
검사하며, TypeScript compiler/registry publish/authentication hook의 production 검증은
애플리케이션 CI가 별도로 소유한다.
