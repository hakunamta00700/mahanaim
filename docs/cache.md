# Cache and conditional responses

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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
