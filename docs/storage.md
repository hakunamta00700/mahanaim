# Object storage

**Audience:** applications storing uploads or generated objects.
**Status:** S3-compatible storage is experimental. **Verified with:** `nimble test`

Use upload validation before any storage operation; see [uploads](uploads.md).
`ObjectStorage` has an in-memory implementation for local/test use and an
S3-compatible bridge around an application-owned transport. The transport owns
endpoint selection, TLS, signing, credential refresh, and provider error
classification; Mahanaim validates bucket/key boundaries and can apply a finite
retry wrapper.

Treat object keys as data, not paths. Reject traversal/empty/ambiguous key input,
generate server-side names when users upload files, and authorize reads before
returning content or a signed provider URL. Provider retries must be bounded;
do not retry a non-idempotent operation blindly or log authorization headers,
object bytes, or credentials.

In-memory storage proves API behavior only. Confirm real S3-compatible service
credentials, TLS, bucket policy, retention, and recovery using provider-specific
staging evidence before production.
