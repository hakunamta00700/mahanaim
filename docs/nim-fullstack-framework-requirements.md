# 풀스택 Nim 웹 프레임워크 기능 요구사항

상태: 초안
확인일: 2026-08-04 (Asia/Seoul)

## 1. 목적과 판정 기준

Nim으로 Django 수준의 서버 렌더링·데이터 모델·관리자 기능과 Litestar 수준의 비동기 API·타입 기반 개발 경험을 하나의 풀스택 웹 프레임워크로 제공한다. Prologue가 이미 제공하는 기능은 재사용·호환 대상으로 삼고, Django와 Litestar의 공식 문서에 나타난 기능은 목표 범위를 결정하는 기준으로 삼는다.

이 문서의 용어는 다음과 같다.

- **현재 지원**: 해당 프레임워크의 공식 문서 또는 공식 저장소가 현재 제공한다고 명시한 기능이다. 제3자 패키지나 커뮤니티 확장은 별도 표시하지 않는다.
- **목표 요구사항**: 새 프레임워크가 제공해야 할 기능이다. `MUST`는 1차 릴리스 필수, `SHOULD`는 1차 릴리스 권장, `MAY`는 후속 확장이다.
- **범위 제외**: 이번 제품의 성공 기준에 포함하지 않는 기능이다. 별도 채택 없이는 지원한다고 간주하지 않는다.

## 2. 조사 기준과 버전

모든 기능 판단은 아래 공식 출처를 2026-08-04에 확인한 결과다.

| 기준 | 확인한 버전/브랜치 | 근거 |
| --- | --- | --- |
| Django | 공식 문서 6.0. 공식 다운로드 페이지의 최신 공식 릴리스는 6.0.7 | [Django 6.0 문서](https://docs.djangoproject.com/en/6.0/), [공식 다운로드·지원 버전](https://www.djangoproject.com/download/) |
| Litestar | 안정 2.x 계열. 확인 시점의 공식 2.x 변경 이력 최신 릴리스는 2.24.0이며, `latest` 문서와 2.x 변경 이력을 기준으로 삼음. 3.x 개발선 전용 내용은 제외 | [Litestar latest 문서](https://docs.litestar.dev/latest/), [사용 문서 목차](https://docs.litestar.dev/latest/usage/index.html), [2.x 변경 이력](https://docs.litestar.dev/2/release-notes/changelog.html), [공식 버전 선택기](https://docs.litestar.dev/main/) |
| Prologue | 공식 저장소 `devel`의 `prologue.nimble`은 0.6.10. Git 태그에서 확인되는 최신 릴리스는 v0.6.6(2024-06-03) | [Prologue 공식 저장소 README](https://github.com/planety/prologue), [devel manifest](https://github.com/planety/prologue/blob/devel/prologue.nimble), [공식 태그 목록](https://github.com/planety/prologue/tags) |

Litestar의 `latest` 문서는 버전 번호를 URL에 고정하지 않으므로, 이 문서에서는 확인일의 2.x 변경 이력에 표시된 2.24.0을 비교 기준으로 기록한다. 구현 시작 시 의존성 파일에서 실제 Litestar 비교 버전을 별도로 고정해야 한다. Prologue는 최신 태그와 `devel` manifest의 버전이 다르므로, “릴리스 안정 기능”과 “현재 개발선 기능”을 구분해 기록한다.

## 3. 기준 프레임워크의 현재 지원 기능

### 3.1 Django 6.0 문서에 명시된 기능

Django 공식 문서의 목차와 각 기능 문서를 기능 인벤토리로 정리하면 다음과 같다.

| 영역 | 현재 지원 |
| --- | --- |
| 프로젝트 기반 | 설정(settings), 애플리케이션(app), `django-admin`/`manage.py`, 사용자 정의 관리 명령, 시스템 검사 프레임워크 |
| 데이터 모델 | 모델·필드·인덱스·메타 옵션·모델 인스턴스, QuerySet·lookup·manager, 관계 탐색, raw SQL, 트랜잭션, 집계·검색·쿼리 표현식·DB 함수, 사용자 정의 필드, 다중 데이터베이스, PostgreSQL 기능 |
| 스키마 변경 | 마이그레이션 생성·실행·작성, migration operation과 SchemaEditor |
| HTTP/뷰 | URLconf, 함수형 뷰, 클래스 기반 뷰·mixins·내장 display/editing views, shortcut·decorator, 요청/응답, TemplateResponse, 비동기 지원, 파일 업로드·Storage API |
| HTML | Django Template Language, 내장 tag/filter, humanization, 사용자 정의 tag/filter, 사용자 정의 template backend |
| 폼 | Form API, field, widget, model form, formset, media, 사용자 정의 validation |
| 관리자 | 자동 admin site, admin action, admin 문서 생성기 |
| 인증/세션 | 인증 시스템, 비밀번호 관리, 인증 사용자 정의, 세션 |
| 웹 보안 | 보안 개요, CSRF, clickjacking, cryptographic signing, Security Middleware, Content Security Policy |
| 공통 웹 도구 | 캐시, 로깅, task framework, 이메일, RSS/Atom syndication, pagination, messages, serialization, sitemap, static files, data validation |
| 국제화 | 국제화·지역화, 지역화된 UI/form 입력, time zone |
| 기타 핵심 | conditional content, content types·generic relations, flatpages, redirects, signals, sites framework, Unicode |
| 특수/운영 | 성능 최적화, GeoDjango, WSGI·ASGI 배포, static 배포, 오류 이메일 추적, deployment checklist |

근거: [Django 문서 목차](https://docs.djangoproject.com/en/6.0/). 이 페이지는 모델·뷰·템플릿·폼·admin·보안·국제화·공통 도구·GeoDjango를 직접 열거한다.

### 3.2 Litestar 안정 문서에 명시된 기능

Litestar는 자체 ORM을 제공하기보다 통합·플러그인과 비동기 ASGI 애플리케이션 조립을 제공한다. 공식 문서의 사용 목차와 API reference를 기준으로 한 현재 지원 목록은 다음과 같다.

| 영역 | 현재 지원 |
| --- | --- |
| 애플리케이션/HTTP | ASGI application, 요청·응답, 상태 코드, 예외 처리, route handler, 함수형·class-based controller, 명시적 path/query/header/cookie/body 파라미터 |
| 라우팅 | 라우터, route handler, controller, HTTP method, typed path parameter, route-level 설정 |
| 타입·데이터 | 타입 기반 data extraction, validation, serialization, DTO(`DataclassDTO`, `MsgspecDTO` 등), Pydantic·attrs·dataclass·TypedDict·msgspec 지원 |
| API 문서 | OpenAPI schema generation, Swagger UI, ReDoc, Stoplight Elements, RapiDoc, schema 설정과 UI plugin |
| 의존성/확장 | 애플리케이션 계층 DI, InitPlugin·플러그인 protocol, custom plugin |
| 데이터베이스 | SQLAlchemy 통합(모델·repository·init/serialization plugin), Piccolo ORM 통합. 자체 ORM은 제공하지 않음 |
| 미들웨어 | allowed hosts, authentication, Brotli compression, CORS, CSRF, logging, rate limit, cookie/server-side session 및 custom middleware |
| 보안 | custom authentication, security backend, guard, JWT backend, endpoint 포함/제외, secret handling |
| 서버 렌더링 | Jinja, Mako, MiniJinja 템플릿 및 template response, HTMX 통합 |
| 상태/실시간 | memory·file·Redis·Valkey stores, caching, channels와 memory/Redis/DB 계열 backend, WebSocket, streaming response, Server-Sent Events |
| 운영 관측 | startup/lifecycle hook, events, background tasks, request logging, 표준/picologging/structlog 로깅, OpenTelemetry, Prometheus metrics |
| 개발 도구 | CLI, debugging, testing utilities, static files, pagination, custom types |
| 응답/웹 UX | file·redirect·template 응답, flash messages, Problem Details 오류 형식, MessagePack |

근거: [Litestar 사용 목차](https://docs.litestar.dev/latest/usage/index.html), [Litestar API reference](https://docs.litestar.dev/latest/reference/index.html), [Litestar 기능 개요와 비교표](https://docs.litestar.dev/latest/). “SQLAlchemy·Piccolo ORM 통합”은 공식 비교표와 데이터베이스 문서의 의미대로 분류하며, Django식 프레임워크 내장 ORM으로 확대 해석하지 않는다.

### 3.3 Prologue 공식 문서/저장소의 현재 지원 기능

아래 목록은 Prologue 공식 README의 Core/Plugin 목록과 공식 가이드 목차·본문을 합친 것이다. 즉, Prologue에 있다고 문서화된 기능을 빠짐없이 범주화하되, “문서에 없다”는 사실만으로 미지원이라고 단정하지 않는다.

| 영역 | 현재 지원 | 상태 메모 |
| --- | --- | --- |
| 설정/서버 | `newSettings`, `.env`, JSON config, 환경변수로 config 선택, address/port/debug/reusePort/appName/secretKey/bufSize, HTTP server backend(asynchttpserver·httpx), `kairos`/Chronos 선택, backend별 추가 설정(maxBody·numThreads) | Core. `devel` manifest 0.6.10에는 Nim 2.0 이상 요구가 명시됨 |
| 애플리케이션 생명주기 | application, startup event, shutdown event, 동기·비동기 event handler | Core |
| Context/HTTP | request·response·session context, request URL/port/path/method/content type/hostname, request/response headers, cookie 읽기·설정·삭제 | Core |
| 입력 데이터 | POST parameter, query parameter, path parameter, form-urlencoded, multipart/form-data, 자동 path/query decode, upload file 조회·저장 | Core |
| 응답 | HTML·plain text·JSON 응답, HTTP status/error response, redirect, attachment/download, 사용자 정의 response, response header | Core |
| 라우팅 | static route, HTTP method, parameter route, wildcard, greedy path, regex route, pattern route, group route, URL building | Core. GET route의 HEAD 자동 등록도 문서화됨 |
| 미들웨어 | global/route middleware, onion-style custom middleware, reusable handler, static file middleware, auth·CORS·clickjacking·CSRF·utils middleware | Core/plugin |
| 정적 파일 | static file response, 여러 static directory serving, download filename, favicon | Core |
| 업로드 | multipart file upload, 원본 파일명·내용 조회, 지정 경로/파일명으로 저장 | Core |
| 세션/메시지 | signed-cookie session, memory session, Redis session, flash messages | Plugin. 공식 문서는 signed-cookie 세션을 민감 정보 저장에 안전하지 않다고 명시함 |
| 오류 | 사용자 정의 404 page, 기본 404/500 handler, 상태 코드별 handler 등록, debug mode의 500 오류 처리 | Core |
| 실시간 | WebSocket echo/송수신 | `websocketx` 확장 설치 필요 |
| 렌더링 | 프레임워크 자체 template engine은 없음. Karax를 서버 사이드 렌더링용 권장 확장으로 안내 | 중요한 현재 한계 |
| API 문서 | OpenAPI JSON을 사용자가 직접 작성하고 `/docs`, `/redocs` route로 제공 | “minimal support”; schema 자동 생성 아님 |
| validation | 단일 값 validator, 여러 form record validator, required/accepted/isInt/min/max 등 helper | Plugin |
| 테스트 | request mocking | Plugin. 공식 README와 가이드 목차에 Mocking 명시 |
| 보안/공통 플러그인 | basic authentication, signing, CORS response, CSRF, clickjacking protection | Plugin |
| 국제화/캐시 | I18n, cache | 공식 README Plugin 목록에 명시 |
| CLI/프로젝트 | `logue init`, `.env` 또는 JSON config 기반 프로젝트 생성, `logue extension <name/all>` 확장 설치 | 공식 CLI 문서 |
| 배포 | Nim binary 컴파일, musl/Alpine, Nginx reverse proxy, Docker 단일/분리 컨테이너, docker-compose, SSL certbot 설정 가이드 | 공식 배포 문서 |

Prologue 근거: [공식 저장소 기능 목록](https://github.com/planety/prologue), [공식 문서 홈/목차](https://planety.github.io/prologue/), [설정](https://planety.github.io/prologue/configure/), [event](https://planety.github.io/prologue/event/), [error handler](https://planety.github.io/prologue/errorhandler/), [headers](https://planety.github.io/prologue/headers/), [request](https://planety.github.io/prologue/request/), [response](https://planety.github.io/prologue/response/), [context](https://planety.github.io/prologue/context/), [routing](https://planety.github.io/prologue/routing/), [middleware](https://planety.github.io/prologue/middleware/), [static files](https://planety.github.io/prologue/staticfiles/), [upload](https://planety.github.io/prologue/uploadfile/), [session](https://planety.github.io/prologue/session/), [server settings](https://planety.github.io/prologue/server/), [WebSocket](https://planety.github.io/prologue/websocket/), [CLI](https://planety.github.io/prologue/cli/), [views](https://planety.github.io/prologue/views/), [OpenAPI](https://planety.github.io/prologue/openapi/), [validation](https://planety.github.io/prologue/validation/), [deployment](https://planety.github.io/prologue/deployment/).

### 3.4 기능 격차 요약

| 기능 축 | Django | Litestar | Prologue | 새 프레임워크의 방향 |
| --- | --- | --- | --- | --- |
| HTTP·라우팅·미들웨어 | 내장, 동기·비동기 지원 | ASGI·비동기·DI 중심 | 내장, async handler·middleware 중심 | Prologue의 저수준 제어를 유지하면서 typed extraction·DI·SSE를 추가 |
| 데이터 모델·ORM·migration | 내장 ORM·migration | SQLAlchemy/Piccolo 등 통합 | 공식 문서 기준 내장 ORM 없음 | Nim 모델 metadata를 ORM·form·DTO·admin·OpenAPI가 공동 사용 |
| 서버 렌더링·폼 | Template·Form·Formset 내장 | Jinja/Mako/MiniJinja·HTMX 통합 | 자체 template engine 없음, Karax 확장 권장 | 안전한 template·form·formset·HTMX를 핵심 기능으로 제공 |
| admin·권한 | 자동 admin·auth·permission | 보안 primitive·guard 중심, 자동 admin 없음 | basic auth 등 plugin 중심, 자동 admin 없음 | 모델 등록만으로 CRUD admin과 RBAC·audit을 제공 |
| API·OpenAPI | Django core에 자동 OpenAPI 없음 | 타입 기반 validation·DTO·OpenAPI 자동 생성 | OpenAPI JSON 수동 작성·최소 serving | Nim 타입에서 DTO·검증·OpenAPI·interactive docs를 자동 생성 |
| 실시간·운영 | ASGI·Channels 등 생태계 활용 | WebSocket·SSE·channels·stores·metrics | WebSocket·cache·session 등 일부 plugin | WebSocket·SSE·background task·observability를 공식 범위에 포함 |

## 4. 제품 목표와 요구사항

### 4.1 제품 경계

프레임워크는 다음 세 가지 사용 방식을 하나의 애플리케이션 모델로 지원해야 한다.

1. **서버 렌더링 앱**: 모델·폼·인증·템플릿·admin을 이용해 JavaScript 없이도 업무 앱을 만들 수 있어야 한다.
2. **API 앱**: Nim 타입에서 입력 검증·직렬화·OpenAPI·오류 응답을 일관되게 도출해야 한다.
3. **혼합형 앱**: 같은 route와 도메인 모델에서 HTML, JSON, HTMX, WebSocket, SSE를 선택할 수 있어야 한다.

모든 요구사항은 Nim의 정적 타입·컴파일 성능·비동기 실행 모델을 우선하며, Prologue의 저마법(low-magic) 사용 경험과 확장성을 유지한다.

### 4.2 필수 요구사항(MUST)

#### 애플리케이션 기반과 CLI

- `NFR-APP-001` 프레임워크는 `new` 또는 동등한 CLI로 프로젝트와 애플리케이션 모듈을 생성하고, 개발/테스트/운영 설정을 분리해야 한다.
- `NFR-APP-002` `.env`와 명시적 JSON/TOML 설정을 지원하고, 비밀값은 로그·오류 화면·빌드 산출물에 노출하지 않아야 한다.
- `NFR-APP-003` 애플리케이션은 startup/shutdown hook, 명시적 error handler, global/route middleware, 사용자 정의 plugin을 등록할 수 있어야 한다.
- `NFR-APP-004` CLI는 개발 서버 실행, 마이그레이션 생성/실행, admin 사용자 생성, 정적 파일 수집, 테스트 실행, OpenAPI 생성, 운영 점검을 제공해야 한다.
- `NFR-APP-005` Nim 버전과 프레임워크 버전을 lockfile/manifest에서 재현할 수 있어야 한다.

#### HTTP·라우팅·응답

- `REQ-HTTP-001` HTTP/1.1 기준으로 method, path, query, header, cookie, form-urlencoded, multipart, JSON body를 타입 안전하게 읽어야 한다.
- `REQ-HTTP-002` static/path/regex/group route, wildcard, typed parameter, route name과 URL building, route-level middleware를 제공해야 한다.
- `REQ-HTTP-003` HTML, text, JSON, file, redirect, streaming, SSE, WebSocket 응답을 동일한 handler 모델에서 제공해야 한다.
- `REQ-HTTP-004` status code, header, cookie, content negotiation, `application/problem+json` 형태의 구조화 오류를 일관되게 지원해야 한다.
- `REQ-HTTP-005` 동기·비동기 handler를 지원하고, blocking 작업이 event loop를 막지 않도록 실행 경계를 문서화·진단해야 한다.

#### 타입·검증·API

- `REQ-API-001` Nim 타입 또는 명시적 schema 선언으로 path/query/header/body의 변환·검증·기본값·제약·에러 위치를 정의해야 한다.
- `REQ-API-002` 동일 모델에서 request DTO와 response DTO를 분리하고, 필드 rename·partial update·nested object·민감 필드 제외를 지원해야 한다.
- `REQ-API-003` JSON과 MessagePack 직렬화, 커스텀 serializer, 날짜·시간·UUID·enum·파일 타입을 제공해야 한다.
- `REQ-API-004` route 선언으로 OpenAPI 3 schema를 자동 생성하고, Swagger UI와 ReDoc 중 최소 두 가지 interactive UI를 제공해야 한다.
- `REQ-API-005` pagination, filtering, sorting, field selection, validation error envelope을 API 공통 기능으로 제공해야 한다.

#### 데이터·ORM·마이그레이션

- `REQ-DATA-001` 선언적 Nim 모델, field type, index, unique/constraint, one-to-one·one-to-many·many-to-many 관계를 제공해야 한다.
- `REQ-DATA-002` query builder/QuerySet, 조건식, 정렬, pagination, aggregate, annotate, eager/lazy loading, raw SQL escape hatch를 제공해야 한다.
- `REQ-DATA-003` migration 생성·검토·실행·롤백/상태 확인과 초기 데이터(fixture/seed)를 CLI로 제공해야 한다.
- `REQ-DATA-004` transaction, savepoint, optimistic/pessimistic locking, connection pool, request 단위 DB session 경계를 제공해야 한다.
- `REQ-DATA-005` SQLite와 PostgreSQL을 1차 지원하고, 다른 backend를 adapter로 추가할 수 있어야 한다. 다중 DB와 read/write routing은 `SHOULD`로 시작한다.
- `REQ-DATA-006` 모델 metadata를 validation·serialization·form·admin·OpenAPI가 재사용하여 중복 선언을 최소화해야 한다.

#### HTML·폼·관리자

- `REQ-UI-001` 안전한 기본 escaping, template inheritance, include/partial, filter/tag/helper, i18n 문법을 갖춘 서버 렌더링 template engine을 제공해야 한다.
- `REQ-UI-002` Nim 타입/모델에서 HTML form을 생성하고, field/widget, CSRF token, model form, formset, field/form validation, 오류 표시를 지원해야 한다.
- `REQ-ADMIN-001` 모델 등록만으로 list/detail/create/update/delete의 기본 admin UI를 생성해야 한다.
- `REQ-ADMIN-002` admin은 검색, 필터, 정렬, pagination, bulk action, 관계형 inline, read-only field, custom column/form/layout을 제공해야 한다.
- `REQ-ADMIN-003` admin은 별도 권한 검사와 audit log를 가지며, 사용자·그룹·권한 관리를 기본 제공해야 한다.
- `REQ-UI-003` HTMX 또는 동등한 partial HTML 교환 패턴과 JSON API를 함께 사용할 수 있어야 한다. 특정 JavaScript SPA framework는 필수 종속성이 아니어야 한다.

#### 인증·보안

- `REQ-SEC-001` 세션 기반 인증과 token/JWT 기반 API 인증을 모두 제공하고, custom authentication backend를 등록할 수 있어야 한다.
- `REQ-SEC-002` 사용자, 그룹/role, permission, route guard, object-level authorization을 지원해야 한다.
- `REQ-SEC-003` 안전한 password hashing, password reset/변경, login/logout, session rotation, brute-force 방어 지점을 제공해야 한다.
- `REQ-SEC-004` CSRF, CORS, clickjacking 방어, CSP/security headers, allowed hosts, signed cookie/token, secret handling을 기본 안전값으로 제공해야 한다.
- `REQ-SEC-005` 파일 업로드의 크기·확장자·MIME 검증, 안전한 파일명·저장소 분리, path traversal 방어를 제공해야 한다.
- `REQ-SEC-006` rate limit, request size limit, timeout, secure cookie, HTTPS deployment checklist를 제공해야 한다.

#### 운영·확장·검증

- `REQ-OPS-001` static files, user uploads, local filesystem, S3 호환 object storage adapter를 제공하고 cache store(memory·Redis)를 추상화해야 한다.
- `REQ-OPS-002` background task와 외부 queue adapter를 제공하고, request lifecycle에서 task를 안전하게 enqueue할 수 있어야 한다.
- `REQ-OPS-003` 구조화 logging, request ID, health/readiness check, metrics, OpenTelemetry tracing hook을 제공해야 한다.
- `REQ-OPS-004` 이메일 backend, pagination, messages/flash, RSS/Atom, sitemap을 서버 렌더링 앱의 공통 도구로 제공해야 한다.
- `REQ-OPS-005` i18n/l10n, timezone-aware 날짜·시간, locale별 숫자·날짜 formatting을 지원해야 한다.
- `REQ-EXT-001` plugin protocol로 route, DI provider, middleware, command, model metadata, admin view, serializer, storage, auth backend를 확장할 수 있어야 한다.
- `REQ-TEST-001` unit/integration test client, request mocking, test database와 transaction isolation, WebSocket/SSE test, live-server smoke test를 제공해야 한다.
- `REQ-TEST-002` 설정·route·모델·migration·보안 설정을 시작 전에 검사하는 system check와 운영 배포 점검 명령을 제공해야 한다.
- `REQ-DOC-001` 모든 핵심 기능에 Nim 예제, API reference, migration guide, 보안 주의사항, 지원 버전 정책을 제공해야 한다.

### 4.3 권장 요구사항(SHOULD)과 후속 요구사항(MAY)

| 우선순위 | 요구사항 |
| --- | --- |
| SHOULD | class-based controller와 function handler를 모두 지원하고, DI scope를 application/request/task로 분리한다. |
| SHOULD | Jinja 계열과 Nim-native compile-time template/component 중 하나를 기본 제공하고, 다른 엔진을 adapter로 연결한다. |
| SHOULD | Redis·Valkey·파일·메모리 store, SQLAlchemy/Piccolo에 해당하는 Nim adapter 생태계 패턴을 제공한다. 단, 특정 ORM을 프레임워크 핵심에 강제하지 않는다. |
| SHOULD | OpenAPI에서 TypeScript client/schema 또는 언어 중립 client artifact를 생성한다. |
| SHOULD | WebSocket channel/group broadcast와 Redis-backed channel layer를 제공한다. |
| SHOULD | Brotli/gzip compression, conditional response, ETag, response caching을 제공한다. |
| SHOULD | Docker multi-stage build, Nginx/reverse proxy, systemd/컨테이너 배포 예제와 graceful shutdown을 제공한다. |
| MAY | Geo/GIS 모델과 spatial query, 다중 tenant/site abstraction, CMS/flatpage 수준의 선택적 패키지를 제공한다. |
| MAY | 공식 frontend asset bundler 또는 JS framework adapter를 제공한다. 핵심 프레임워크는 frontend toolchain과 독립적으로 유지한다. |
| MAY | 분산 task scheduler, full-text search adapter, 실시간 presence, GraphQL을 별도 공식 패키지로 제공한다. |

## 5. 범위 제외

다음 항목은 이 요구사항의 1차 성공 기준에서 제외한다.

- Python Django 또는 Litestar API와의 소스/바이너리 호환, 기존 Django third-party app이나 Litestar plugin의 자동 포팅.
- 특정 데이터베이스 하나에 종속된 프레임워크 내장 DB 서버, 관리형 클라우드·PaaS·Kubernetes control plane.
- React/Vue/Svelte 같은 특정 SPA runtime, Node.js 기반 bundler, 프레임워크가 소유하는 frontend component library.
- 결제·메일 발송 사업자·OAuth 제공자·검색엔진 같은 외부 서비스의 계정/운영. 필요한 연결점과 adapter contract만 제공한다.
- Prologue 공식 문서에 없는 ORM/admin/template engine을 “현재 Prologue 기능”으로 간주하는 것. 이 문서에서는 이들을 새 프레임워크의 **목표 요구사항**으로만 다룬다.
- 성능 수치의 무근거 보장. 목표 benchmark와 지원 트래픽은 구현 후 동일 조건에서 측정하고 버전별로 공개한다.

## 6. 기능 매핑과 1차 수용 기준

| 기능 축 | Prologue 현재 자산 | Django/Litestar에서 보강할 목표 | 1차 수용 기준 |
| --- | --- | --- | --- |
| HTTP/라우팅 | async context, method/path/regex/group route, middleware, HTML/JSON response | typed extraction, DI, streaming/SSE, structured errors | 예제 앱이 HTML·JSON·upload·WebSocket route를 같은 앱에서 통과 |
| 렌더링/폼 | response helper, upload/form params, Karax 외부 확장 | 내장 template, model form, CSRF·validation·formset | CRUD 화면이 별도 SPA 없이 생성·검증·오류 표시 |
| 데이터 | Prologue 자체 ORM 기능은 조사 문서에 없음 | 모델·QuerySet·migration·transaction·admin 연계 | SQLite/PostgreSQL CRUD와 migration up/down, 관계 query 테스트 통과 |
| API | minimal manual OpenAPI, validation helper | 자동 OpenAPI, DTO/serialization, pagination, API errors | route 선언만으로 schema·interactive docs·검증 실패 응답 생성 |
| 인증/보안 | basic auth, session 종류, signing, CSRF, CORS, clickjacking | user/permission/RBAC, password management, JWT, CSP/rate limit | 보안 회귀 테스트와 배포 checklist가 모두 통과 |
| 운영 | settings, events, static, cache, Docker/Nginx 가이드 | background tasks, stores, email, logging/metrics/tracing, checks | 운영 설정에서 health check·request ID·graceful shutdown 확인 |
| 확장/검증 | middleware, reusable handler, mocking, CLI extensions | plugin protocol, test DB/client, app checks, docs generation | custom plugin 하나가 route·command·admin을 추가하고 통합 테스트 통과 |

## 7. 구현 순서

1. **기반선**: application/config/CLI, HTTP adapter, context, router, response, middleware, lifecycle, 오류 모델.
2. **Prologue 호환 자산**: static/upload/session/cookie, validation, WebSocket, mocking, OpenAPI route serving을 우선 adapter 또는 호환 API로 제공.
3. **Django형 풀스택 핵심**: ORM/model metadata, migration, transaction, template, form, user/auth/permission, admin.
4. **Litestar형 API 핵심**: DI, DTO, 자동 OpenAPI/UI, stores/cache, streaming/SSE, background tasks, observability.
5. **운영 품질**: security defaults, system checks, test utilities, deployment recipes, compatibility and performance benchmarks.

각 단계는 문서 예제와 회귀 테스트가 함께 있어야 다음 단계로 이동한다. 특히 ORM·인증·admin은 서버 렌더링과 API가 같은 모델 metadata를 공유하는지 검증한다.

## 8. 추적성 메모

- Django의 admin, ORM/migration, forms, auth, security, i18n, common web tools는 [공식 6.0 문서 목차](https://docs.djangoproject.com/en/6.0/)에서 직접 확인했다.
- Litestar의 DI, DTO, middleware, OpenAPI, plugins, security, stores, templating, testing, WebSockets, SQLAlchemy/Piccolo 통합은 [공식 latest 사용 목차](https://docs.litestar.dev/latest/usage/index.html)와 [API reference](https://docs.litestar.dev/latest/reference/index.html)에서 확인했다.
- Prologue의 Core/Plugin 기능과 `devel` 버전은 [공식 저장소 README](https://github.com/planety/prologue)와 [manifest](https://github.com/planety/prologue/blob/devel/prologue.nimble)에서 확인했고, 동작 세부사항은 [공식 문서 홈](https://planety.github.io/prologue/)에서 연결되는 각 가이드로 대조했다.
- 조사 기준일 이후 기능이 바뀔 수 있으므로 구현 시작 시 위 URL과 버전을 다시 확인하고, 변경된 기능은 이 문서의 “현재 지원/목표/범위 제외” 분류를 함께 갱신한다.
### 2026-08-05 implementation status — channel/group broadcast

- [x] SHOULD baseline: framework-neutral `ChannelLayer` group subscribe/publish/unsubscribe contract and deterministic in-memory backend.
- [x] SHOULD baseline: idempotent subscription cleanup, invalid group/subscriber validation, and isolated subscriber callback failure.
- [ ] SHOULD remaining: Redis/Valkey cross-process fan-out and reconnect/ordering/backpressure policy. WebSocket session lifecycle integration is complete for the local adapter-neutral binding.
- [x] SHOULD baseline extension: `bindWebSocketSession`이 channel delivery와 WebSocket `send`를 연결하고 session close 시 subscription을 자동 해제한다.
- [x] SHOULD adapter boundary: `CallbackChannelLayer`가 Redis/Valkey 등 외부 broker callback을 공통 channel contract에 연결한다. 실제 broker wire와 cross-process 운영 검증은 남아 있다.
- [x] SHOULD protocol baseline: Redis/Valkey `PUBLISH`·`SUBSCRIBE`·`UNSUBSCRIBE` RESP2 codec와 pub/sub event validation을 제공한다.
- [ ] SHOULD remaining: dedicated async broker subscription, cross-process fan-out, reconnect·ordering·backpressure live 검증.
- [x] SHOULD protocol extension: 기존 Redis/Valkey RESP client가 `PUBLISH`를 실행하고 subscriber count를 strict integer response로 검증한다.
- [x] SHOULD async baseline: dedicated Redis/Valkey subscription socket이 coalesced RESP frames, subscribe/unsubscribe acknowledgement와 local callback delivery를 loopback contract로 제공한다.
- [ ] SHOULD remaining: reconnect·backpressure·cross-process production fan-out 및 distributed `ChannelLayer` wiring.
- [x] SHOULD reconnect baseline: 원격 단절 후 reader 종료·새 socket 연결·active channel 재구독을 수행하는 explicit reconnect contract를 loopback으로 검증한다.
- [ ] SHOULD remaining: retry/backoff orchestration, ordering·backpressure, production cross-process fan-out.
- [x] SHOULD retry baseline: reconnect max attempts와 exponential delay bound를 검증하고 bounded async retry로 재구독 성공 attempt를 반환한다.
- [ ] SHOULD remaining: message ordering·backpressure 및 production cross-process fan-out.
