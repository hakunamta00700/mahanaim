# External adapters

**Audience:** developers bridging a provider into a Mahanaim contract.
**Verified with:** contract tests plus provider-specific live evidence.

Template, storage/cache, database, authentication, channel, and durable-job
adapters use narrow framework-neutral contracts. The application chooses and
configures a concrete provider. An adapter owns provider translation, bounded
retry, and error classification; it must not silently report a failed external
operation as a framework success.

The application owns endpoint/credential selection, TLS, secret rotation,
availability policy, monitoring, and deployment recovery. Keep provider payloads
and credentials out of errors/logs, close resources at the declared owner
boundary, and support cancellation only where the provider contract safely allows
it. A local callback/in-memory adapter is not proof of production provider wire
semantics.
