# Channel layers

**Audience:** applications faning out realtime events across sessions or processes.
**Status:** Redis/Valkey support is experimental. **Verified with:** `nimble test`, `nimble redisLive`

Use the in-memory layer for one-process tests, callback layers for an
application-controlled provider, and `RedisChannelLayer` for a Redis/Valkey
boundary. Publish/subscribe order, backpressure, reconnect, and shutdown rules
are explicit delivery policy decisions; do not treat a successful local publish
as cross-process delivery proof.

Bound pending messages and define a drop/retry behavior for slow subscribers.
During rolling deployment, drain subscriptions, stop accepting new connections,
allow a bounded grace period, then reconnect consumers. Run the Redis/Valkey live
gate with real credentials/service settings before claiming production support.
## 실행 예제와 Redis 경계

[`examples/jobs_realtime_channels.nim`](../examples/jobs_realtime_channels.nim)은
in-memory layer에서 subscribe/publish/unsubscribe를 실행하고, `RedisChannelLayer`는
연결 없이 configuration만 생성한다. 이는 기본 backpressure 설정을 문서와 함께
검증하기 위한 credential-free 경계다. 실제 Redis/Valkey start, remote subscribe,
cross-process delivery, reconnect는 `nimble redisLive`와 disposable service에서
검증하며, 성공 전에는 production delivery 보장을 주장하지 않는다.
