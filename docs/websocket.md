# WebSockets

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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
## 실행 예제

[`examples/jobs_realtime_channels.nim`](../examples/jobs_realtime_channels.nim)은
`newTestClient`로 `/rooms/42` WebSocket route에 text frame을 보내고 echo와 정상 close를
검증한다. `nimble docsExamples`의 `jobs-realtime-channels-ok`은 in-process framing과
route 계약의 증거다. 실제 TLS upgrade, proxy timeout, disconnect, Redis fan-out은
deployment/provider live gate에서 별도로 검증해야 한다.
