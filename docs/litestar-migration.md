# Litestar에서 이관

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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
