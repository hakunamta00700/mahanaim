# Extension package contracts

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
