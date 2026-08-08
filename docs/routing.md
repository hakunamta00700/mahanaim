# Routing and middleware

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** application developers registering HTTP or WebSocket endpoints.
**Verified with:** `nimble test`

Register every route while building the `Application`, before `startup`. A route
name is unique across HTTP and WebSocket routes and is the stable key for link
generation.

```nim
import std/[asyncdispatch, httpcore, tables]
import mahanaim

let app = newApplication()

app.get("/products/:id<int>", "products.detail",
  proc (request: Request): Future[Response] {.async, gcsafe.} =
    let id = request.pathParams["id"]
    return jsonResponse("{\"id\":" & id & "}"))

app.addRoute("DELETE", "/products/:id<int>", "products.delete",
  proc (request: Request): Future[Response] {.async, gcsafe.} =
    return textResponse("deleted", Http204))
```

`get` and `post` are short forms for common methods. Use `addRoute` for every
other HTTP method. `getSync`, `postSync`, `putSync`, `patchSync`, and
`deleteSync` are explicit synchronous variants; they run through the configured
executor only when synchronous handlers are allowed. Prefer async handlers for
network and database work.

## Route success and failure contracts

Use the route form that describes the input shape, and test the matching
success plus its rejection path. A route miss never invokes the handler.

| Route form | Success example | Failure result | Verification |
| --- | --- | --- | --- |
| static `GET /health` | `GET /health` returns the handler's `200` response | an unknown path returns `404` | `router dispatches exact routes` |
| typed `/products/:id<int>` | `/products/42` sets `pathParams["id"]` | `/products/not-a-number` is a route miss (`404`) | `router supports typed parameters, wildcard paths, groups, and URL building` |
| wildcard `/files/*path` | `/files/a/report.txt` binds the remaining path | an empty or nonmatching prefix returns `404` | `router supports typed parameters, wildcard paths, groups, and URL building` |
| same path, different method | `DELETE /products/42` reaches the explicit `addRoute` handler | `POST /products/42` returns `405` when no POST route exists | `router dispatches the correct method when paths are shared` |
| named URL | `urlFor("products.detail", {"id": "42"})` yields `/products/42` | missing or invalid parameters raise `ValueError` before a link is emitted | `router supports typed parameters, wildcard paths, groups, and URL building` |
| WebSocket `app.websocket` | a valid upgrade enters the session handler | HTTP and WebSocket registries are separate; a missing WebSocket path is not an HTTP route | `WebSocket routes use a separate registry and preserve path precedence` |

Do not hide authorization or validation failures in route matching. Register the
route first, then use the security and validation policies to return their
documented `401`/`403` or problem-response failures.

## Paths and parameters

| Pattern | Meaning |
| --- | --- |
| `/users/:id` | one URL-decoded path segment, available as `pathParams["id"]` |
| `/users/:id<int>` | one segment constrained to `int` before the handler runs |
| `:value<uint>`, `:value<float>`, `:value<bool>` | supported scalar constraints |
| `/files/*path` | one or more remaining segments, joined by `/` |

Static routes outrank typed parameters, which outrank untyped parameters and
wildcards. Equal scores retain registration order. A mismatched type is a route
miss (normally 404); a matching path under another method returns 405.

Use `app.router.urlFor` for named URLs. It rejects missing or invalid parameters
and encodes values so a value cannot change the route shape.

```nim
let url = app.router.urlFor("products.detail", {"id": "42"}.toTable)
# /products/42
```

## Groups and middleware order

Groups carry a prefix and shared middleware without implicit global state.

```nim
let api = app.group("/api/v1", @[authenticate])
app.get(api, "/products", "api.products.list", listProducts)
app.post(api, "/products", "api.products.create", createProduct,
  @[requireEditor])
```

Global middleware runs in registration order. For a grouped route, the order is
global middleware → group middleware → route middleware → handler; response
handling unwinds in the reverse order. Security middleware is installed first
by `newApplication`, so a replacement must preserve its security policy.

## WebSockets

WebSockets are registered separately because their handler owns a session,
rather than returning an HTTP body.

```nim
app.websocket("/ws/notifications", "notifications.socket",
  proc (request: Request, session: WebSocketSession): Future[void] {.async, gcsafe.} =
    await session.send(textWebSocketMessage("connected")))
```

See the realtime guide for session lifecycle and deployment constraints.
