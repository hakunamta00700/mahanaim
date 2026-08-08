# Channel layers

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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
