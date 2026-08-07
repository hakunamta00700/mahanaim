# Optional domain decisions

These domains are deliberately outside the core dependency graph. A consumer
must select a package or integration explicitly; no optional SDK is added to
`mahanaim.nimble` by these decisions.

| Domain | Decision | Required security/data boundary |
| --- | --- | --- |
| Geo/GIS | third-party integration guide | spatial query input is bound/validated; geometry access follows application authorization |
| Multi-tenancy | first-party package planned | tenant identity is resolved before repository/storage access; tenant identifier is included in every cache/object/channel key |
| CMS/content | third-party integration guide | draft/published authorization, escaped rendering, immutable audit history for publishing actions |
| Full-text search | third-party integration guide | index credentials are redacted; tenant/document filters are server-enforced before results return |
| Frontend integration | intentionally transport-neutral | assets use `StaticCollectionPolicy`; Node bundlers and SPA runtimes are application-owned |
| Real-time presence | package planned | authenticated, tenant-scoped membership with TTL and disconnect cleanup; see extension package contract |

A planned package cannot be promoted to stable merely by adding an import. It
must publish its data-isolation model, failure behavior, lifecycle integration,
support matrix row, and independent compile/test gate first.
