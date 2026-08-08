# Mahanaim

Mahanaim은 Nim으로 Django와 Litestar에 견줄 수 있는 풀스택 웹 프레임워크를 설계·구현하기 위한 프로젝트입니다.

## 목표

하나의 Nim 애플리케이션에서 다음을 함께 제공하는 것을 목표로 합니다.

- 서버 사이드 렌더링, 템플릿, 폼, 관리자 화면
- 타입 안전한 API, 입력 검증, DTO, 자동 OpenAPI 문서
- ORM, migration, transaction, 인증·권한
- WebSocket, SSE, background task, 캐시와 관측성
- Prologue의 단순하고 확장 가능한 HTTP 기반

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
- [시작 가이드](docs/getting-started.md) · [프로젝트 구조](docs/project-layout.md) · [CLI 레퍼런스](docs/cli-reference.md)
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

요구사항 문서는 Django 6.0, Litestar 2.x, Prologue의 공식 문서를 비교 기준으로 작성했습니다. 현재 저장소에는 framework-neutral core, adapter, contract test와 실행 가능한 최소 수직 슬라이스가 포함되어 있으며, 외부 staging/live 증거는 계획에서 별도로 추적합니다.

## 로드맵

1. HTTP 서버·라우팅·middleware·lifecycle 기반
2. Prologue 호환 자산과 확장 API
3. 모델·ORM·migration·transaction
4. template·form·auth·permission·admin
5. typed API·DTO·OpenAPI·WebSocket·SSE
6. 테스트 도구·보안 기본값·운영 관측성

## 라이선스

이 프로젝트는 [MIT License](LICENSE)로 배포됩니다. 이 표기는
`mahanaim.nimble`의 `license = "MIT"` 선언과 같은 설치·배포 계약이다.
