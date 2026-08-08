# 응답과 콘텐츠 협상

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** route authors serving browser, API, file, stream, SSE, or WebSocket clients.
**Verified with:** `nimble test`

Response helpers make the representation explicit:

| Helper | Default content type / representation |
| --- | --- |
| `textResponse` | `text/plain; charset=utf-8` |
| `htmlResponse` | `text/html; charset=utf-8` |
| `jsonResponse` | `application/json; charset=utf-8` |
| `fileResponse` | application-owned file; reads and validates an existing file |
| `streamResponse` | stream representation with the supplied media type |
| `sseResponse` | `text/event-stream`, no-cache, keep-alive |
| `webSocketResponse` | HTTP 101 upgrade metadata |

```nim
proc product(request: Request): Future[Response] {.async, gcsafe.} =
  return responseVariants([
    htmlResponse("<h1>Product</h1>"),
    jsonResponse("{\"name\":\"Product\"}")
  ])
```

`Application.dispatch` selects a response using `Accept`. When no offered
representation matches, it returns 406 `Not Acceptable`; successful negotiated
responses add `Vary: Accept`. A 204 or redirect with no body remains valid even
when an `Accept` value names no body representation. Keep all variants
semantically equivalent and test the accepted and rejected media types.

## Representation success and failure contracts

The table separates a response constructor's local preconditions from
negotiation failures that happen later in `Application.dispatch`.

| Representation | Success case | Failure or safety boundary | Verification |
| --- | --- | --- | --- |
| text, HTML, JSON | matching `Accept` selects the corresponding `200` variant | unsupported `Accept` returns `406 Not Acceptable` | `response policy selects an accepted representation` |
| file | an authorized existing regular file produces the declared content type | empty, missing, or non-regular paths are rejected before transport access | `response constructors expose file representation safely` |
| stream | an adapter writes a chunked stream representation | callers must supply an adapter-supported media type and cannot rely on buffered cache semantics | `network adapter writes stream responses with chunked transfer framing` |
| SSE | `SseEvent` becomes `text/event-stream` with no-cache headers | newlines in `event` or `id` are rejected to prevent framing injection | `SSE event and id fields reject line injection` |
| WebSocket | an accepted upgrade exposes `rrWebSocket` metadata | use `app.websocket`; a normal HTTP body is not a WebSocket session | `WebSocket core contract preserves frame kinds and adapter boundary` |
| HTML/HTMX/JSON | full HTML, fragment, or JSON is selected with `Vary: Accept, HX-Request` | an unacceptable media type returns `406`, even for the helper | `HTML JSON response helper selects HTMX partials and JSON` |

For every API response, record the status code and content type alongside both
the success body and the validation, authentication, or negotiation failure.

## Browser, HTMX, and JSON from one endpoint

`htmlJsonResponse(request, fullHtml, partialHtml, jsonBody)` chooses a partial
only for `HX-Request: true`, otherwise a full HTML document, and still allows
JSON negotiation. It always sets `Vary: Accept, HX-Request` so shared caches do
not mix a fragment with a full page or API response. See the focused
[`htmx-example`](htmx-example.md) and the forthcoming HTMX guide.

## Files, streams, and SSE

`fileResponse` accepts a nonempty existing regular-file path; authorize before
selecting it, and never build a path from unchecked user input. `streamResponse`
marks a response for adapter streaming but its current body remains framework
metadata. For SSE, pass structured `SseEvent` values; `event` and `id` reject
line breaks to prevent framing injection, while `data` may be multiline.

```nim
let events = [SseEvent(event: "progress", id: "42", retryMs: 5000,
  data: "finished")]
return sseResponse(events)
```

WebSocket endpoints normally use `app.websocket` rather than returning an HTTP
response. The adapter owns the handshake and session transport; see the routing
and realtime documentation before exposing an upgrade route.
