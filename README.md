# Mahanaim

Mahanaim은 **낮은 마법(low-magic)**, 명시적인 adapter 경계, 재현 가능한 검증을
중심으로 설계한 Nim 풀스택 웹 프레임워크입니다. Django와 Litestar가 제공하는
개발 경험을 참고하되, HTTP·데이터베이스·메시지 브로커·배포 환경의 소유권을
애플리케이션 코드에서 숨기지 않는 것을 우선합니다.

> **개발 상태:** `0.1.0` 개발 프리뷰입니다. 공개 API 안정성 등급과 변경 정책은
> [API 안정성 정책](docs/api-stability-policy.md)을 따르며, 아직 안정 버전이나
> 프로덕션 준비 완료를 의미하지 않습니다.

## 현재 제공 범위

| 영역 | 제공 기능 |
| --- | --- |
| 애플리케이션 코어 | 격리된 `Application`, lifecycle hook, middleware, plugin·DI 경계, 오류 정책 |
| HTTP·라우팅 | async/sync handler, route group, 이름 있는 route, compact route DSL, Prologue·stdlib·httpx adapter |
| 응답·입력 | HTML·JSON·MessagePack 응답, body parser, multipart upload, validation, idempotency |
| 데이터 | model metadata·macro, SQLite adapter, 선택적 PostgreSQL adapter, migration, transaction, repository, query component |
| 화면·관리 | template engine·adapter, form, localization, static asset collection, admin resource·audit 경계 |
| 인증·보안 | account auth, authorization, CSRF·보안 header 정책, Argon2id·bcrypt, login throttling, secret redaction |
| API·실시간 | OpenAPI 및 TypeScript client 생성, WebSocket, SSE, channel layer, Redis/Valkey 연동 경계 |
| 작업·저장소 | background/durable job, SQLite durable store, object storage·S3 signing, email·syndication 경계 |
| 운영 | request ID, health/readiness, metrics, tracing, bounded executor, graceful shutdown, release checksum |

각 기능이 모든 backend와 운영 환경에서 동일한 수준으로 검증됐다는 뜻은 아닙니다.
지원 runtime, 선택 adapter, 외부 live gate의 현재 범위는
[지원 매트릭스](docs/support-matrix.md)와
[운영 가이드](docs/operations-guide.md)에서 확인하세요.

## 요구 사항

- Nim `>= 2.2.0`
- Nimble
- 개발·CI 기준 버전: Nim `2.2.4`
- 선택 기능에 따라 SQLite, PostgreSQL/libpq, Redis 또는 Valkey 등의 외부 runtime

## 시작하기

### 저장소에서 실행

```text
git clone https://github.com/hakunamta00700/mahanaim.git
cd mahanaim
nimble install --depsOnly
nimble build
nimble docsExamples
```

`nimble docsExamples`는 공개 package entry point를 사용하는
[`examples/minimal_app.nim`](examples/minimal_app.nim)을 실제로 컴파일하고 실행합니다.
정상 실행 결과에는 `minimal-app-ok`가 출력됩니다.

### 최소 애플리케이션

```nim
import std/[asyncdispatch, httpcore]
import mahanaim

let app = newApplication()

app.get("/", "home",
  proc(request: Request): Future[Response] {.async, gcsafe.} =
    discard request
    return htmlResponse("<h1>Hello from Mahanaim</h1>"))

app.startup()
try:
  let response = waitFor app.dispatch(newRequest("GET", "/"))
  doAssert response.status == Http200
finally:
  app.shutdown()
```

이 예제는 socket server가 아니라 framework-neutral dispatch 계약을 실행합니다.
실제 네트워크 listener는 애플리케이션이 선택한 Prologue, stdlib 또는 httpx adapter가
소유합니다.

### Route DSL

동기 작업과 비동기 작업의 실행 경계가 코드에 드러나도록 route 종류를 명시합니다.

```nim
routes app:
  getSync "/", "home", handlers.index
  post "/events", "events.create", handlers.create
  websocket "/ws", "events.socket", service.handleSocket
```

지원 선언은 `get`, `post`, `getSync`, `postSync`, `putSync`, `patchSync`,
`deleteSync`, `websocket`입니다. 동기 handler는 애플리케이션의 bounded executor
정책을 통과합니다.

## CLI

`nimble build`는 `mahanaim_cli` 실행 파일을 생성합니다.

```text
mahanaim_cli new NAME [PATH]
mahanaim_cli dev
mahanaim_cli check
mahanaim_cli test
mahanaim_cli db status|migrate|up|rollback [PATH]
mahanaim_cli jobs run [max]|recover
mahanaim_cli openapi [PATH]
mahanaim_cli openapi-ts [PATH]
mahanaim_cli admin create-user <identifier> [subject]
mahanaim_cli static collect <source...> --output <path>
```

데이터베이스, 사용자 생성, durable job처럼 상태를 변경하는 명령은 embedding
애플리케이션이 persistence callback과 정책을 명시적으로 구성해야 합니다. CLI가
연결 정보나 저장 방식을 임의로 추측하지 않습니다.

## 설정

기본 개발 설정은 `127.0.0.1:8000`, request timeout `30,000ms`입니다. `.env`,
JSON, TOML 설정을 합성할 수 있으며 process environment가 가장 높은 우선순위를
갖습니다.

주요 환경 변수:

```text
MAHANAIM_ENV=development
MAHANAIM_DEBUG=true
MAHANAIM_HOST=127.0.0.1
MAHANAIM_PORT=8000
MAHANAIM_REQUEST_TIMEOUT_MS=30000
MAHANAIM_EXECUTOR_MAX_CONCURRENT_JOBS=0
MAHANAIM_EXECUTOR_MAX_QUEUED_JOBS=0
```

`SECRET_*` 값은 별도 secret store에 들어가며, 구조화된 확장 값은
`MAHANAIM_VALUE_*`에 JSON으로 전달할 수 있습니다. 설정값과 secret을 로그에
직접 출력하지 마세요.

## 검증

일반적인 로컬 검증 순서:

```text
nimble test
nimble check
nimble verify
nimble docsCheck
git diff --check
```

- `nimble test`: framework test suite
- `nimble check`: CLI compile
- `nimble verify`: build, lockfile, 문서 예제, 공개 API compile 계약
- `nimble planStatus`: `plan.md`의 완료·부분 완료·미착수 항목 집계
- `nimble postgresLive`, `nimble redisLive`, `nimble beastLive`,
  `nimble httpsLive`: 자격 증명·서비스·OS가 필요한 선택 live gate

정확한 완료 조건은 [Definition of Done](docs/definition-of-done.md)을 따릅니다.
외부 서비스가 없어서 skip된 결과는 live integration 통과 증거로 간주하지 않습니다.

## 저장소 구조

```text
src/mahanaim.nim       공개 package entry point
src/mahanaim/          framework-neutral core와 adapter
src/mahanaim_cli.nim   CLI frontend
examples/              실행 가능한 공개 API 예제
tests/                 unit·contract·compile·live fixture
benchmarks/            deterministic benchmark workload
docs/                  설계·지원·운영·배포 문서
deploy/                Docker, nginx, systemd 배포 템플릿
tools/                 계획 상태와 release manifest 도구
```

## 주요 문서

- [기능 요구사항](docs/nim-fullstack-framework-requirements.md)
- [요구사항별 구현 계획](docs/nim-fullstack-framework-implementation-plan.md)
- [API 안정성 정책](docs/api-stability-policy.md)
- [지원 매트릭스](docs/support-matrix.md)
- [운영 가이드](docs/operations-guide.md)
- [보안 배포 체크리스트](docs/security-deployment-checklist.md)
- [배포 레시피](docs/deployment-recipes.md)
- [Storage와 ORM 통합](docs/storage-and-orm-integration.md)
- [HTMX 예제](docs/htmx-example.md)
- [Definition of Done](docs/definition-of-done.md)

## 현재 제약

- `0.1.0` 개발 프리뷰이며 API 변경 가능성이 있습니다.
- PostgreSQL은 `-d:mahanaimPostgres` 또는 명시적 adapter import를 사용해야 하며,
  SQLite-only 애플리케이션은 libpq를 로드하지 않습니다.
- Redis/Valkey, PostgreSQL, HTTPS reverse proxy, Beast/httpx wire 검증은 별도
  서비스나 플랫폼 gate가 필요합니다.
- TLS 인증서 발급·갱신은 프레임워크가 아니라 reverse proxy 또는 ingress의
  책임입니다.
- 관리자 기능은 resource·authorization·audit 계약을 제공하지만, 애플리케이션별
  업무 UI와 persistence 정책을 자동 생성하지 않습니다.

## 로드맵과 진행 상황

Canonical 상태는 [`plan.md`](plan.md)에 있습니다. 현재 항목 수를 추측하지 말고
다음 명령으로 저장소의 실제 체크리스트를 집계하세요.

```text
nimble planStatus
```

상세 요구사항과 외부 staging 증거는 구현 계획 문서에서 별도로 추적합니다.

## 라이선스

`mahanaim.nimble` package metadata는 MIT로 설정되어 있습니다. 독립적인
`LICENSE` 파일은 아직 저장소에 포함되어 있지 않으므로 배포 전에 라이선스 문서를
확정해야 합니다.
