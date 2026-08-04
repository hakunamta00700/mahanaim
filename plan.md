# Mahanaim 구현 계획

상태: 진행 중  
작성일: 2026-08-04  
상세 요구사항: [docs/nim-fullstack-framework-requirements.md](docs/nim-fullstack-framework-requirements.md)  
상세 실행 기록: [docs/nim-fullstack-framework-implementation-plan.md](docs/nim-fullstack-framework-implementation-plan.md)

이 문서는 요구사항을 구현 가능한 단위로 추적하기 위한 상위 체크리스트다. 각 항목은 코드, 테스트, 문서가 함께 완료될 때 `[x]`로 변경한다.

## 우선순위 기준

| 우선순위 | 판단 기준 | 대표 범위 |
|---|---|---|
| P0 | 모든 기능의 기반이거나 보안·정합성을 직접 좌우함 | 공통 요청 모델, 라우터, middleware, lifecycle, 설정, 오류, 테스트 |
| P1 | 첫 번째 실사용 CRUD/API 제품을 완성함 | 모델, migration, DB adapter, serializer, typed API, admin 기초 |
| P2 | 운영 안정성과 확장성을 높임 | observability, rate limit, timeout, background job, plugin/DI |
| P3 | 핵심 경로와 분리 가능한 선택 기능 | 고급 template, WebSocket/SSE 확장, 추가 backend, CLI 확장 |

원칙: P0의 계약과 회귀 테스트를 먼저 고정하고, P1은 P0 API 위에서 구현하며, P2/P3는 안정적인 extension point 뒤에 둔다.

## P0 — 프레임워크 기초와 실행 경로

### 공통 계약

- [x] `Request`, `Response`, `Handler`, `Middleware`, `Route`의 framework-neutral 계약을 고정한다.
- [x] `Application`이 router, middleware, lifecycle, security, error policy를 소유하도록 한다.
- [x] sync handler를 명시적 adapter와 executor 경계로 감싼다.
- [x] 요청 timeout과 cooperative cancellation token을 공통 dispatch 경계에 추가한다.
- [x] deprecated std threadpool을 taskpools backend로 교체하고 GC-managed response를 copy-safe worker buffer로 bridge한다.
- [x] executor 동시 실행 상한과 capacity exhausted 오류 계약을 추가한다.
- [x] executor 동시 실행 상한을 AppConfig와 process environment provider에 연결한다.
- [x] 취소된 sync 작업이 worker에서 user handler에 진입하지 않는 cooperative pre-start cancellation을 추가한다.
- [x] 실행 중 cooperative cancellation 신호를 atomic token으로 전달하고 worker가 안전 지점에서 종료하도록 한다.
- [ ] blocking 자동 감지와 강제 backend cancellation 정책을 추가한다.

### HTTP와 라우팅

- [x] exact, named parameter, typed parameter, wildcard, route group, named URL을 구현한다.
- [x] method dispatch, 404/405 fallback, middleware composition을 검증한다.
- [x] Prologue request/response adapter와 catch-all server bridge를 제공한다.
- [x] static first-segment prefix index와 dynamic fallback을 추가하고 기존 precedence를 보존한다.
- [x] wildcard URL building 인코딩 정책을 확정하고 예약 문자가 route shape를 바꾸지 않게 한다.
- [x] 내부 route tree matching으로 static/parameter/wildcard 후보를 좁히고 precedence를 보존한다.
- [x] 고정 route cardinality와 반복 횟수의 deterministic router benchmark suite를 추가한다.
- [x] Prologue raw form body와 `Content-Type`을 공통 body parser로 연결하고 contract test를 추가한다.
- [x] multipart upload storage에 filename traversal, size, MIME, overwrite 정책을 추가한다.
- [ ] Prologue upload/WebSocket adapter와 종료 가능한 socket-level smoke fixture를 추가한다.

### 입력·출력과 오류

- [x] JSON, form-urlencoded, multipart body parser와 body-scoped validation error를 제공한다.
- [x] HTML/JSON/text representation과 `Accept` 기반 406 응답을 제공한다.
- [x] stream/SSE/WebSocket representation metadata와 core response helper를 추가한다.
- [x] 표준 HTTP adapter에서 SSE representation framing을 TCP wire로 검증한다.
- [x] 표준 TCP adapter의 stream/SSE 응답을 실제 chunked transfer wire로 통합한다.
- [x] 표준 TCP adapter의 WebSocket upgrade와 기본 text/binary/control frame wire를 통합한다.
- [x] 표준 HTTP·Windows Prologue adapter의 단일 response `Accept` negotiation과 406 wire 정책을 통합한다.
- [x] 표준 HTTP adapter에서 buffered/stream/SSE representation variant를 `Accept` 기준으로 wire 선택한다.
- [x] Windows Prologue live fixture에서 variant 선택과 WebSocket upgrade `Accept` bypass를 검증한다.
- [x] stdlib와 Beast/httpx native socket을 공통 WebSocket byte transport와 session contract로 연결한다.
- [ ] Beast backend의 실제 live fixture와 backend 공통 WebSocket representation policy를 완성한다.
- [x] 표준 network adapter의 close 중 serve cancellation을 graceful shutdown으로 정리한다.
- [x] application-level error handler와 problem JSON envelope를 제공한다.

### 설정과 보안

- [x] `.env`, JSON, TOML flat key/value, process environment provider와 precedence를 구현한다.
- [x] secret store, redaction, secure response headers, allowed host, CORS, body size limit을 구현한다.
- [x] signed value/cookie와 CSRF HMAC 계약을 구현한다.
- [x] 앱별 fixed-window rate limit과 429/quota headers 정책을 구현한다.
- [x] 요청 timeout과 cooperative cancellation 정책을 구현한다.
- [x] signed cookie keyring 검증과 legacy key 감지·rotation primitive를 구현한다.
- [x] TOML 전체 문법 파서를 연결하고 AppConfig scalar schema validation을 구현한다.
- [ ] session binding/auth integration, 분산 rate limit, retry/backpressure 정책을 구현한다.

### Prologue 호환 계층

- [x] Prologue 0.6.8 의존성과 lockfile을 고정한다.
- [x] mocking request 및 mocking context에서 adapter와 lifecycle을 검증한다.
- [x] Prologue form body를 core body parser 계약으로 변환한다.
- [x] Prologue multipart upload API를 core BodyPart/upload storage 계약으로 변환한다.
- [x] WebSocket frame kind와 adapter-owned session callback core 계약을 추가한다.
- [x] Prologue WebSocket API와 Windows native request upgrade adapter를 구현한다.
- [x] Windows stdlib Prologue backend에 adapter-owned transport, ephemeral port, graceful close smoke fixture를 추가한다.
- [ ] Prologue backend별 socket ownership과 종료 가능한 socket-level smoke fixture를 완성한다.
- [ ] 실제 TCP 요청·응답과 graceful shutdown을 검증할 fixture를 만든다. Prologue 기본 backend의 비공개 서버 소유권 문제를 먼저 해결한다.

### 개발 품질

- [x] `nimble test`, `nimble verify`, `nimble check`를 CI와 동일하게 실행한다.
- [x] lockfile 기반 dependency 설치와 기본 CI를 구성한다.
- [ ] 지원 OS/Nim matrix와 release artifact checksum 검증을 추가한다.
- [ ] 모든 기능의 Definition of Done을 적용한다: 구현, 단위/통합 테스트, 문서, 회귀 검증.

### 2026-08-04 구현 기록

- [x] TOML provider가 `parsetoml`로 전체 TOML 문법을 읽고, 지원 scalar와 `secrets.*`를 공통 설정 표현으로 flatten한다.
- [x] TOML 배열·날짜·미등록 키를 조용히 버리지 않고 안전한 `ValueError`로 거부한다.
- [x] TOML dependency lock, 설정 회귀 테스트, `nimble build`/`nimble test`를 검증한다.
- [ ] 아직 AppConfig에 대응하지 않는 배열·날짜·복합 타입의 schema mapping을 추가한다.

## P1 — 첫 실사용 풀스택 제품

### 데이터와 모델

- [x] backend-neutral field/index/constraint/relation metadata와 model registry를 제공한다.
- [x] metadata 기반 JSON serializer와 sensitive/nullable/rename 정책을 제공한다.
- [ ] model macro, nested DTO, patch projection, date/UUID/file adapter를 제공한다.
- [ ] SQLite/PostgreSQL query adapter, migration up/down, transaction, relation query를 제공한다.

### API와 서버 렌더링

- [x] named field extraction, scalar coercion, validation error aggregation을 제공한다.
- [ ] macro 기반 schema와 일반 응답 타입, OpenAPI 생성, 완전한 content negotiation을 제공한다.
- [ ] template/render context와 HTML form binding을 제공한다.
- [ ] CRUD resource convention과 admin extension point를 제공한다.

## P2 — 운영·확장성

- [ ] structured logging, metrics, tracing, request ID, health/readiness endpoint를 제공한다.
- [ ] rate limit, timeout, retry/backpressure, graceful shutdown을 운영 정책으로 고정한다.
- [ ] plugin manifest, DI provider, command/admin extension point를 제공한다.
- [ ] background task/job abstraction과 persistence·retry 정책을 제공한다.
- [ ] test database transaction isolation, live-server fixture, WebSocket/SSE test client를 제공한다.

## P3 — 선택 확장

- [ ] 추가 HTTP backend와 deployment adapter를 제공한다.
- [ ] 고급 template engine, OpenAPI UI, WebSocket/SSE 고급 기능을 확장한다.
- [ ] 프로젝트 생성 CLI, migration CLI, admin CLI를 제품 수준으로 확장한다.

## 탄탄한 기반을 위한 설계 규칙

1. **도메인 계약 우선**: Prologue는 transport adapter로 격리하고 core 타입이 Prologue 타입을 노출하지 않게 한다.
2. **단일 책임**: request 변환, route matching, middleware, security, response rendering, lifecycle을 별도 모듈로 유지한다.
3. **명시적 실행 경계**: sync/blocking 작업은 executor를 통해서만 실행하고 cancellation·timeout 계약을 함께 둔다.
4. **실패를 타입화**: 검증·라우팅·설정·보안 오류를 상태 코드와 구조화된 envelope로 일관되게 반환한다.
5. **보안 기본값**: secure cookie/header, body limit, host/CORS 정책을 opt-out이 아닌 안전한 기본값으로 둔다.
6. **테스트 피라미드**: 순수 core unit test → adapter contract test → 실제 loopback/live-server smoke test 순서로 검증한다.
7. **문서와 코드를 함께 변경**: 기능을 완료할 때 구현 체크, 테스트 체크, 문서 체크, CI 검증을 같은 커밋 단위로 남긴다.
8. **확장점은 늦게 공개**: 내부 구현을 먼저 안정화하고 plugin/DI/backend API는 최소 계약으로 공개한다.

## 완료 판정

- [ ] P0의 미완료 항목이 없고, 전체 테스트·verify·check가 통과한다.
- [ ] P1에서 SQLite/PostgreSQL CRUD와 migration 회귀 테스트가 통과한다.
- [ ] 운영 기능은 실패 시나리오와 복구 절차까지 문서화한다.
- [ ] 각 릴리스가 지원 버전, 의존성 lock, 보안 기본값, 변경 로그를 명시한다.
