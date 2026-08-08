# OpenAPI and generated clients

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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
