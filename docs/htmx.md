# HTMX and progressive enhancement

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** HTML applications that also need fragments or JSON clients.
**Verified with:** `nimble test`

Use `htmlJsonResponse` when a route serves a normal HTML document, HTMX fragment,
and JSON representation. Data is loaded once; only the representation changes.

```nim
proc products(request: Request): Future[Response] {.async, gcsafe.} =
  let items = loadProducts()
  return htmlJsonResponse(request,
    engine.render("products/page", productContext(items)),
    engine.render("products/list", productContext(items)),
    productsJson(items))
```

Browser navigation receives the full page. `HX-Request: true` receives the
partial. `Accept: application/json` selects JSON; an unacceptable explicit type
receives 406. The helper sets `Vary: Accept, HX-Request`, preventing cached
fragments, documents, and API data from being mixed.

Make the ordinary link or form work without HTMX, then add `hx-*` as an
enhancement. Preserve the same authorization and data policy for every
representation. See [responses and negotiation](responses-and-negotiation.md)
and [the compact example](htmx-example.md).

[`examples/template_form_htmx.nim`](../examples/template_form_htmx.nim)은 동일한
Application에서 full HTML, `HX-Request` partial, JSON, form 오류를 dispatch해
검증하는 실행 예제다. `nimble docsExamples`로 실행한다.
