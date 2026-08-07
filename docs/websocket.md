# WebSockets

**Audience:** developers serving authenticated bidirectional sessions.
**Status:** experimental. **Verified with:** `nimble test`

Register a separate WebSocket route with `app.websocket`. The handler receives a
`Request` and adapter-owned `WebSocketSession`; use `send`, `receive`, and
`close` with `WebSocketMessage` helpers. Validate application payloads after the
handshake and close invalid/unauthorized sessions with a permitted close code.

Authenticate and authorize before joining a group or exposing data. Session
transport, TLS upgrade, proxy timeouts, and disconnect behavior are adapter and
deployment concerns; test them against the deployed reverse proxy, not only the
in-process route contract. Use channel layers for cross-session fan-out rather
than sharing mutable application state.
