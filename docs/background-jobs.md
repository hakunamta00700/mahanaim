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
