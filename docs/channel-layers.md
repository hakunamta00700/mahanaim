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
