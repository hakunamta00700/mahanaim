# Routing and middleware

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
