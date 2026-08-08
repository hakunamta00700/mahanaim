# Admin operations

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
