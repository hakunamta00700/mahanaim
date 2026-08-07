# Cache and conditional responses

**Audience:** applications selecting a local or Redis/Valkey cache boundary.
**Status:** Redis/Valkey cache is experimental. **Verified with:** `nimble test`, `nimble redisLive`

`InMemoryCacheStore` is bounded LRU-like local storage with monotonic TTL expiry.
`RedisCacheStore` uses the configured RESP client for GET/SET/SETEX/DEL. Cache
transport failure is never converted into a cache hit or successful write; define
an application stale-value/single-flight policy when stampede protection matters.

Set a bounded TTL and key namespace. Do not put credentials or unvalidated user
input directly in keys. Check Redis/Valkey compatibility, server TTL, maxmemory,
and eviction policy in the real provider environment; a local in-memory cache
does not demonstrate distributed eviction or clock behavior.

Response ETag/304 handling is separate from application data caching. The
framework applies ETags after content negotiation for buffered responses; it does
not generate ETags for streams, SSE, or WebSocket upgrades. See the operations
guide for conditional response and provider monitoring details.
