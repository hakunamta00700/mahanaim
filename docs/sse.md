# Server-sent events

**Audience:** applications streaming one-way events over HTTP.
**Status:** experimental. **Verified with:** `nimble test`

`sseResponse` serializes structured `SseEvent` values and sets
`text/event-stream`, `Cache-Control: no-cache`, and keep-alive headers. `event`
and `id` reject CR/LF to prevent SSE framing injection; `data` can be multiline.

Use an event ID and bounded replay/reconnect policy owned by the application.
Deploy proxies that do not buffer SSE responses and whose idle/read/write timeout
fits the event heartbeat policy. Authorize the initial HTTP request and do not
put bearer secrets in an EventSource URL query string.
