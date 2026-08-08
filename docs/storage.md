# Object storage

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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
