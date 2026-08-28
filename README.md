# Mahanaim

Mahanaim은 **낮은 마법(low-magic)**, 명시적인 adapter 경계, 재현 가능한 검증을
중심으로 설계한 Nim 풀스택 웹 프레임워크입니다. Django와 Litestar가 제공하는
개발 경험을 참고하되, HTTP·데이터베이스·메시지 브로커·배포 환경의 소유권을
애플리케이션 코드에서 숨기지 않는 것을 우선합니다.

> **개발 상태:** `0.1.0` 개발 프리뷰입니다. 공개 API 안정성 등급과 변경 정책은
> [API 안정성 정책](docs/api-stability-policy.md)을 따르며, 기능별 production
> 준비 상태는 [지원 매트릭스](docs/support-matrix.md)의 증거를 기준으로 판단합니다.

## 현재 제공 범위

| 영역 | 제공 기능 |
| --- | --- |
| 애플리케이션 코어 | 격리된 `Application`, lifecycle hook, middleware, plugin·module·DI 경계, 오류 정책 |
| HTTP·라우팅 | async/sync handler, route group, 이름 있는 route, Prologue·stdlib·httpx adapter |
| 응답·입력 | HTML·JSON·MessagePack, body parser, multipart upload, validation, idempotency |
| 데이터 | model metadata·macro, SQLite, 선택적 PostgreSQL, migration, transaction, repository, query component |
| 화면·관리 | template·form·HTMX 표현, localization, static asset, admin resource·template·audit 경계 |
| 인증·보안 | account auth, authorization, CSRF·보안 header, Argon2id·bcrypt, throttling, secret redaction |
| API·실시간 | OpenAPI·TypeScript client, WebSocket, SSE, channel layer, Redis/Valkey 연동 경계 |
| 작업·저장소 | background/durable job, SQLite durable store, object storage·S3 signing, email·syndication 경계 |
| 운영 | request ID, health/readiness, metrics, tracing, bounded executor, graceful shutdown, release checksum |

각 기능이 모든 backend와 운영 환경에서 같은 성숙도라는 뜻은 아닙니다. 현재
`application-routing`, `dependency-injection`, `sqlite-storage`,
`observability-testing-cli`는 stable이며, 외부 provider나 live 증거가 더 필요한
기능은 experimental로 구분됩니다.

## 요구 사항

- Nim `>= 2.2.0`
- Nimble
- 현재 개발·CI 기준 버전: Nim `2.2.10`
- 선택 기능에 따라 SQLite, PostgreSQL/libpq, Redis 또는 Valkey 등의 외부 runtime

## 새 사용자 빠른 시작

Nim `>= 2.2.0`과 Nimble이 PATH에 있다고 가정한다. 저장소에서 CLI를 빌드한 뒤
새 프로젝트를 만들고, 생성 프로젝트 안에서 dependency 설치·test·pre-flight 실행을
순서대로 수행한다.

```powershell
nimble install
nimble build
.\mahanaim_cli.exe new shop ./shop
cd shop
nimble install
nimble test
nimble run -- dev
```

Unix에서는 `./mahanaim_cli`를 사용한다. `dev`는 설정과 route/model/security
pre-flight를 실행하며, 실패하면 종료 코드 `1`로 원인을 출력한다. 다음에는
`mahanaim app catalog`로 모듈을 추가하고 [시작 가이드](docs/getting-started.md),
[프로젝트 구조](docs/project-layout.md), [CLI 레퍼런스](docs/cli-reference.md),
[기능 매핑](docs/feature-map.md), [운영 가이드](docs/operations-guide.md)에서
각 경로를 이어간다.

## 실행 예제

저장소를 복제한 개발자는 아래 예제로 public API의 최소 route·dispatch·lifecycle
흐름을 즉시 확인할 수 있다. 예제는 `nimble docsExamples`에서 컴파일·실행된다.

| 예제 | 목적 | 실행 명령 | 기대 결과 |
| --- | --- | --- | --- |
| [`local_storage.nim`](examples/local_storage.nim) | 안전한 local upload·정적 수집·TTL cache | `nimble docsExamples` | `local-storage-ok` |
| [`api_artifacts.nim`](examples/api_artifacts.nim) | OpenAPI JSON·TypeScript client artifact 생성 | `nimble docsExamples` | `api-artifacts-ok` |
| [`plugin_extension.nim`](examples/plugin_extension.nim) | plugin route·service와 manifest 오류 | `nimble docsExamples` | `plugin-extension-ok` |
| [`admin_audit.nim`](examples/admin_audit.nim) | 권한 HTML CRUD와 audit event | `nimble docsExamples` | `admin-audit-ok` |
| [`admin_templates.nim`](examples/admin_templates.nim) | Admin template override와 `formLayout` 우선순위 | `nimble docsExamples` | `admin-templates-ok` |
| [`template_form_htmx.nim`](examples/template_form_htmx.nim) | template·form·HTMX/JSON representation | `nimble docsExamples` | `template-form-htmx-ok` |
| [`sqlite_crud_migration.nim`](examples/sqlite_crud_migration.nim) | SQLite metadata·migration·repository CRUD·rollback | `nimble docsExamples` | `sqlite-crud-migration-ok` |
| [`jobs_realtime_channels.nim`](examples/jobs_realtime_channels.nim) | durable job·SSE·WebSocket·channel layer의 local 경로 | `nimble docsExamples` | `jobs-realtime-channels-ok` |
| [`minimal_app.nim`](examples/minimal_app.nim) | `Application`에 HTML·JSON route를 등록하고 in-process request를 검증 | `nimble docsExamples` | `minimal-app-ok` 출력, 종료 코드 `0` |

## 5분 시작

```text
mahanaim new shop ./shop
cd shop
mahanaim app catalog
nimble test
```

생성된 프로젝트의 composition root에 `catalogModule()`을 설치한 뒤 route와
provider를 명시적으로 구성한다. 자세한 과정은 [시작 가이드](docs/getting-started.md)를
따른다.

## 문서

- [문서 안내](docs/index.md) — 목적별 전체 문서 인덱스
- [시작 가이드](docs/getting-started.md) · [프로젝트 구조](docs/project-layout.md) · [CLI 레퍼런스](docs/cli-reference.md) · [API 레퍼런스](docs/api-reference/README.md)
- [기능 매핑](docs/feature-map.md) — Django/Litestar 개념과 현재 지원 상태
- [지원 범위와 기능 성숙도](docs/support-matrix.md)
- [운영 가이드](docs/operations-guide.md) · [배포 레시피](docs/deployment-recipes.md) · [릴리스 지원 정책](docs/support-policy.md)
- [Admin 템플릿 커스터마이징](docs/admin-template-customization.md)
- [요구사항](docs/nim-fullstack-framework-requirements.md) · [구현 계획](docs/nim-fullstack-framework-implementation-plan.md) · [API 안정성 정책](docs/api-stability-policy.md)

## 프로젝트와 앱 생성

```text
mahanaim new shop ./shop
cd shop
mahanaim app catalog
```

`mahanaim app`은 `src/catalog.nim` 모듈과 `tests/test_catalog.nim` 테스트를
만들며, 앱은 프로젝트의 composition root에서 `catalogModule()`로 명시적으로
설치한다. 기존 파일은 덮어쓰지 않는다.

## 검증

```text
nimble test
nimble check
nimble verify
nimble docsCheck
git diff --check
```

`nimble verify`는 CLI build, lockfile, 문서 계약, 전체 public API reference,
실행 가능한 예제와 공개 API compile 계약을 확인합니다. PostgreSQL, Redis/Valkey,
Beast/httpx, HTTPS처럼 외부 서비스나 특정 OS가 필요한 기능은 해당 live gate가
별도로 필요하며, 환경 부재로 skip된 결과를 integration 통과로 간주하지 않습니다.

## 저장소 구조

```text
src/mahanaim.nim       공개 package entry point
src/mahanaim/          framework-neutral core와 adapter
src/mahanaim_cli.nim   CLI frontend
examples/              실행 가능한 공개 API 예제
tests/                 unit·contract·compile·live fixture
benchmarks/            deterministic benchmark workload
docs/                  사용자·API·지원·운영·배포 문서
deploy/                Docker, nginx, systemd 배포 템플릿
tools/                 계획 상태와 release manifest 도구
```

## 현재 제약

- `0.1.0` 개발 프리뷰이며 experimental API는 변경될 수 있습니다.
- PostgreSQL은 명시적 adapter opt-in이 필요하며 SQLite-only 애플리케이션은
  libpq를 로드하지 않습니다.
- Redis/Valkey, PostgreSQL, S3, SMTP, HTTPS reverse proxy, Beast/httpx의 운영
  보장은 각 provider·platform live gate의 실제 증거가 필요합니다.
- TLS 인증서 발급·갱신은 reverse proxy 또는 ingress의 책임입니다.
- Admin, 인증, background job, realtime 기능은 애플리케이션별 권한·persistence·
  provider 구성을 대신하지 않습니다.

## 로드맵과 진행 상황

Canonical 상태는 [`plan.md`](plan.md)에 있습니다. 현재 체크리스트는 다음 명령으로
저장소에서 직접 집계합니다.

```text
nimble planStatus
```

상세 요구사항과 외부 staging 증거는 구현 계획과 지원 매트릭스에서 별도로
추적합니다.

## 라이선스

이 프로젝트는 [MIT License](LICENSE)로 배포됩니다. 이 표기는
`mahanaim.nimble`의 `license = "MIT"` 선언과 같은 설치·배포 계약이다.
