# Core application API

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](../support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](../support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](../index.md) · [지원 매트릭스](../support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](../support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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
