# Background jobs

**Audience:** applications scheduling bounded asynchronous work.
**Status:** durable queues are experimental. **Verified with:** `nimble test`

`BackgroundJobQueue` runs bounded in-process work through the executor.
`enqueueIdempotent` requires a stable key, so retrying a request does not create
unbounded duplicate work. `JobScheduler` supports `scheduleAt` and
`scheduleEvery`; handlers must still be safe to run more than once.

For recovery across process restart, use `DurableJobRegistry` with the SQLite
durable store and the `jobs run` / `jobs recover` commands. SQLite is local
durability, not a distributed broker. External durable stores are adapter
boundaries: they own provider acknowledgement, retry classification, credentials,
and production recovery proof.

Make each task idempotent, give retries finite budgets, record a correlation ID,
and separate retryable provider failure from permanent validation failure. Do not
claim provider delivery guarantees based only on the in-memory queue or local test.
## 실행 예제

[`examples/jobs_realtime_channels.nim`](../examples/jobs_realtime_channels.nim)은
SQLite durable store에 `email` 작업을 넣고 named handler를 `runNext`로 한 번 실행한다.
다음 명령은 job 처리, SSE, WebSocket, channel layer의 로컬 계약을 함께 검증한다.

```powershell
nimble docsExamples
```

성공 표시는 `jobs-realtime-channels-ok`이다. 이 예제의 SQLite store는 local durable
store이며 분산 broker가 아니다. Redis/Valkey 또는 다른 provider의 delivery/retry/ack는
provider adapter와 credential 환경에서 별도로 검증한다.
