# Admin operations

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** operators provisioning and auditing administrative access.
**Status:** experimental.
**Verified with:** `nimble test`

Create the first account through the application-owned provisioning callback and
`mahanaim admin create-user`. Supply secrets through an approved deployment
secret mechanism, never in source, terminal history, or a checked-in `.env`.
Separate provisioners, editors, auditors, and deployment administrators into
distinct roles.

The read-only Admin inspector supports `admin resources` and `admin audit` from
an explicit registry. It is a diagnostic tool, not a route authorization bypass.
Preserve SQLite audit storage through normal database backups and test a restore
on an isolated copy before an incident.

Audit events intentionally contain action/resource/identifier/actor only. Send
external logs through a redacting observability pipeline, define retention and
access policy, and rotate credentials/invalidate sessions after a suspected
administrative access incident.

권한 있는 CRUD와 audit record의 local contract는
[`examples/admin_audit.nim`](../examples/admin_audit.nim)을 `nimble docsExamples`로
실행해 확인한다. durable audit store의 backup/restore 및 role provisioning은 운영
환경의 별도 runbook과 증거가 필요하다.
