# Email and notifications

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** applications delivering email, flash messages, feeds, and discovery metadata.
**Status:** SMTP delivery is experimental. **Verified with:** `nimble test`

`EmailMessage` is delivered through callback, SMTP, or bounded retry transports.
The application owns recipient validation, template rendering, idempotency, and
provider credentials. Require authenticated TLS for SMTP and test a disposable
wire endpoint before production; the callback transport is a local/test boundary.

Flash messages are request/session scoped and consumed once. Sitemap and RSS/Atom
helpers render escaped XML and reject unsafe URLs. They are output helpers, not
an authorization mechanism: only publish public URLs and do not include private
identifiers or secrets in feed data.
