# 서버 렌더링 페이지

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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
