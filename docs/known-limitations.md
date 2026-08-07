# Known limitations and support boundaries

The [support matrix](support-matrix.md) is the source of truth for maturity and
evidence. Stable contracts are covered by the listed local/CI gates; experimental
features need the additional provider or browser/live evidence named there.

Current non-goals or unavailable features include plugin scaffold/registry search,
dynamic/hot plugin loading, semantic-version dependency solving, Geo/GIS, CMS,
multi-tenancy, full-text search, presence, GraphQL, and distributed scheduling.
Mahanaim does not promise Django-style automatic model/app discovery or complete
Admin widget/package compatibility.

PostgreSQL, Redis/Valkey, S3-compatible storage, SMTP, background brokers,
transport adapters, WebSocket/SSE, and OpenAPI have provider/deployment boundaries.
Use the linked storage, cache, realtime, deployment, and API guides; never infer
external-wire support solely from an in-memory or compile-only test.

When a needed feature is outside this list's supported scope, integrate it behind
an explicit application-owned adapter or retain the existing system boundary.
