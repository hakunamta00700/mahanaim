# Adoption and release guide

## Start an SSR/admin application

Create a complete starter project with `mahanaim new shop ./shop`. Inside that
project, `mahanaim app catalog` creates `src/catalog.nim` and
`tests/test_catalog.nim`; it refuses to overwrite an existing module or test.
Install the generated `catalogModule()` explicitly in the project's composition
root, then compose templates, forms, account authentication, and `AdminRegistry`.
Run locally with the same compiler configuration used in CI, and use the network
fixture to exercise browser routes before deployment. For an admin deployment,
select a durable audit store, configure CSRF/HTTPS policy, create the first
administrator through `mahanaim admin create-user`, and verify that the audit
database is in the backup/restore runbook.

Admin의 기본 UI는 파일 기반 템플릿으로 제공된다. `AdminRegistry`를 만든 뒤
`registerAdminRoutes` 전에 `admin.loadAdminTemplateDirectory("templates")`를
호출하면 `templates/admin/` 아래의 전역 또는 리소스별 화면을 덮어쓸 수 있다.
화면 이름과 컨텍스트는 [Admin 템플릿 커스터마이징](admin-template-customization.md)을
따른다.

## Start a versioned API/service

Register DTO-backed routes with an explicit URL or header API version policy,
generate the OpenAPI document/client through the CLI, and configure JWT or
introspection authentication before exposing the listener. Put PostgreSQL,
Redis/Valkey, SMTP, object-store, broker, and gRPC/GraphQL choices behind their
documented application-owned adapters; their optional live gates are evidence,
not defaults selected by importing core.

## Upgrade, security, and rollback

Read `api-stability-policy.md`, apply migrations through `mahanaim db status`
then `db up`, and record the rollback command before changing production
traffic. Follow `security-deployment-checklist.md` for proxy/TLS, secret,
cookie, CSRF, backup, and access-log requirements. A rollback stops new traffic,
marks readiness false, drains requests/jobs within the configured budget,
restores the previous binary/configuration, and then records the deployment
result in the operations runbook.

## Release qualification

Run the portable gates locally:

```text
nimble test
nimble verify
nimble check
nimble docsCheck
nimble docsExamples
git diff --check
```

The GitHub Actions matrix runs these gates and produces release manifests on
Linux, Windows, and macOS. Provider evidence is intentionally scoped: run
`postgresLive`, `redisLive`, `httpsLive`, and `beastLive` only with disposable
or approved credentials/services, attach their results to the release record,
and do not relabel an experimental provider feature as stable without staging
TLS renewal, reconnect, drain, and rollback evidence.
