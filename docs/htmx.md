# HTMX and progressive enhancement

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
