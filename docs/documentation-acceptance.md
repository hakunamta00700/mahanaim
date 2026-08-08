# 문서 수용 검증 runbook

**책임 경계:** 프레임워크는 생성기·검증 명령과 문서를 제공하고, 프로젝트는 생성 앱을 보관하며, 외부 provider는 staging credential·비용·가용성 증거를 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; staging provider 범위는 experimental이다.
**선행 조건:** clean checkout, Nim, Git, staging 담당자의 승인된 disposable endpoint.
**대상 독자:** 신규 사용자, Django/Litestar 이관 사용자, 운영 담당자.
**안정성 기준:** local 명령 성공은 provider/staging 보장을 대체하지 않는다.
**마지막 검증:** `nimble docsCheck`, `nimble docsExamples`, `nimble verify`.
**관련 문서:** [시작](getting-started.md) · [Django 전환](django-migration.md) · [Litestar 전환](litestar-migration.md) · [배포](deployment.md) · [운영](operations-guide.md)

## 신규 사용자와 이관 사용자

각 persona는 새 빈 작업 폴더에서 다음을 실행하고, terminal 출력과 생성된
`tests/` 결과를 review evidence로 첨부한다. 실제 credential은 사용하지 않는다.

```sh
mahanaim new notes
cd notes
nimble test
mahanaim check
```

성공 기준은 `nimble test` 종료 코드 0, `check`의 error 0, 그리고
`src/notes.nim`에 생성된 health route다. Django 사용자는 project/app·admin·command
대응을 [Django 전환](django-migration.md) 표에서, Litestar 사용자는 DTO·DI·OpenAPI
대응을 [Litestar 전환](litestar-migration.md) 표에서 각각 하나씩 적용한다.
실패하면 생성 폴더를 보존하고 명령·Nim 버전·오류를 issue에 기록한다.

## 운영 staging rehearsal

1. [배포](deployment.md)의 Docker/nginx 또는 systemd 절차로 disposable staging을 배포한다.
2. `/health`와 `/ready`, Prometheus endpoint, request ID 로그를 확인한다.
3. backup 확인 뒤 migration `status`, `up`, smoke request를 실행한다.
4. 이전 artifact로 rollback하고 migration rollback 가능 여부·health 회복·queue drain을 기록한다.
5. TLS certificate chain과 renewal은 `MAHANAIM_HTTPS_URL`을 설정한 `nimble httpsLive`로 검증한다.

성공 증거는 deploy revision, UTC 시각, health/ready 응답, migration revision,
rollback revision, certificate issuer/expiry, `httpsLive` 출력이다. credential이 없으면
명시적 skip 사유와 담당자를 남기며 이를 stable 승격 근거로 사용하지 않는다.
