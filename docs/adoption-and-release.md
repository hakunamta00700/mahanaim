# 도입과 릴리스 가이드

**대상 독자:** Mahanaim을 도입하거나 릴리스를 준비하는 기술 책임자·운영자
**선행 조건:** [시작 가이드](getting-started.md), [지원 매트릭스](support-matrix.md)
**안정성 기준:** provider·staging 증거가 필요한 기능은 experimental로 유지한다.
**검증:** `nimble test`, `nimble verify`, `nimble docsCheck`

## SSR/Admin 애플리케이션 시작

`mahanaim new shop ./shop`으로 완전한 starter project를 만든다. 이 프로젝트에서
`mahanaim app catalog`은 `src/catalog.nim`과 `tests/test_catalog.nim`을 만들며,
기존 module이나 test를 덮어쓰지 않는다. 생성된 `catalogModule()`은 프로젝트
composition root에 명시적으로 설치하고, 이후 template·form·계정 인증·`AdminRegistry`를
조합한다. 배포 전에 CI와 같은 compiler 설정으로 로컬 실행하고 network fixture로
browser route를 검사한다. Admin 배포에서는 durable audit store를 선택하고 CSRF/HTTPS
정책을 설정한 뒤 `mahanaim admin create-user`로 첫 관리자를 만든다. audit database가
backup/restore runbook에 포함됐는지도 확인한다.

Admin의 기본 UI는 파일 기반 템플릿으로 제공된다. `AdminRegistry`를 만든 뒤
`registerAdminRoutes` 전에 `admin.loadAdminTemplateDirectory("templates")`를
호출하면 `templates/admin/` 아래의 전역 또는 리소스별 화면을 덮어쓸 수 있다.
화면 이름과 컨텍스트는 [Admin 템플릿 커스터마이징](admin-template-customization.md)을
따른다.

## 버전 API/서비스 시작

명시적인 URL 또는 header API version 정책으로 DTO route를 등록하고, listener를
공개하기 전에 CLI로 OpenAPI document/client를 생성하며 JWT 또는 introspection 인증을
구성한다. PostgreSQL, Redis/Valkey, SMTP, object store, broker, gRPC/GraphQL은
문서화된 application-owned adapter 뒤에 둔다. 선택적 live gate는 import만으로
선택되는 기본값이 아니라 증거다.

## 업그레이드·보안·롤백

`api-stability-policy.md`를 읽고 `mahanaim db status` 다음 `db up`으로 migration을
적용한다. production traffic을 바꾸기 전에 rollback 명령을 기록한다.
`security-deployment-checklist.md`에서 proxy/TLS, secret, cookie, CSRF, backup,
access log 요구사항을 확인한다. 롤백은 새 traffic을 중지하고 readiness를 false로
표시하며, 정해진 예산 안에서 request/job을 drain한 뒤 이전 binary/configuration을
복원하고 결과를 운영 runbook에 기록한다.

## 릴리스 적합성

다음 이식 가능한 gate를 로컬에서 실행한다.

```text
nimble test
nimble verify
nimble check
nimble docsCheck
nimble docsExamples
git diff --check
```

GitHub Actions matrix는 이 gate를 Linux·Windows·macOS에서 실행하고 release
manifest를 만든다. provider 증거의 범위는 의도적으로 제한된다. `postgresLive`,
`redisLive`, `httpsLive`, `beastLive`는 disposable 또는 승인된 credential/service가
있을 때만 실행하고 결과를 release record에 첨부한다. staging TLS 갱신, reconnect,
drain, rollback 증거 없이 experimental provider 기능을 stable로 바꾸지 않는다.
