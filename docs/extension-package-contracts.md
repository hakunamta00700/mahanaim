# 확장 패키지 계약

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

Mahanaim core intentionally owns HTTP dispatch, lifecycle, authentication,
serialization, and the channel abstraction only. The following capabilities
are independently versioned packages; importing `mahanaim` never pulls their
transport libraries into an application.

| Package | Status | Core boundary | Required package contract |
| --- | --- | --- | --- |
| `mahanaim-graphql` | planned | typed DTO/OpenAPI metadata, `ApplicationModule`, WebSocket | schema/resolver lifecycle, auth before resolver execution, subscription ordering/backpressure, JSON error envelope |
| `mahanaim-grpc` | planned | application dispatch, DI scopes, authentication | protobuf serialization, deadline/cancellation bridge, unary/streaming error mapping, graceful listener shutdown |
| `mahanaim-broker` | planned | `ChannelLayer`, `CallbackChannelLayer`, durable jobs | broker acknowledgement, retry/dead-letter policy, bounded publisher/subscriber buffers, reconnect and drain behavior |
| `mahanaim-presence` | planned | channel groups, authenticated request context | tenant-scoped presence keys, TTL/heartbeat, authorization before membership publication, disconnect cleanup |

Each package must expose an explicit `install(app: Application)` or
`ApplicationModule`, must close its resources through the application lifecycle,
and must not bypass Mahanaim authorization or request/task scopes. Transport
payloads use versioned schemas; unknown versions, oversized messages, and a
full backpressure queue fail with a documented error rather than unbounded
buffering. Package tests must compile without importing other optional packages
and include an opt-in interoperability fixture for their selected transport.

`ChannelLayer` and `CallbackChannelLayer` are stable core extension points.
They provide in-memory/test delivery and application-owned broker callbacks,
not a promise of a particular broker wire protocol. GraphQL, gRPC, and broker
clients remain intentionally unavailable from core until their package contract
and release gate exist.
