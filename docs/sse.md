# Server-sent events

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** applications streaming one-way events over HTTP.
**Status:** experimental. **Verified with:** `nimble test`

`sseResponse` serializes structured `SseEvent` values and sets
`text/event-stream`, `Cache-Control: no-cache`, and keep-alive headers. `event`
and `id` reject CR/LF to prevent SSE framing injection; `data` can be multiline.

Use an event ID and bounded replay/reconnect policy owned by the application.
Deploy proxies that do not buffer SSE responses and whose idle/read/write timeout
fits the event heartbeat policy. Authorize the initial HTTP request and do not
put bearer secrets in an EventSource URL query string.
## 실행 예제

[`examples/jobs_realtime_channels.nim`](../examples/jobs_realtime_channels.nim)은
`/events`에서 `ready` SSE event를 반환하고 `getSseEvents`로 event/id/data framing을
검증한다. `nimble docsExamples`에서 `jobs-realtime-channels-ok`이 출력되어도 실제
proxy buffering과 reconnect 정책은 운영 환경에서 검증해야 한다.
