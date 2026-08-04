# Mahanaim 운영 정책과 복구 절차

이 문서는 현재 코어에서 실제로 제공하는 운영 경계와, 아직 외부 adapter가
필요한 기능의 책임 범위를 고정한다. 운영 환경에서는 정책을 코드의 기본값에
의존하지 말고 `AppConfig`, `ExecutionPolicy`, `SecurityPolicy`로 명시한다.

## 요청 추적과 health

- 모든 dispatch 요청은 유효한 `X-Request-ID`를 보존하고, 없거나 안전하지 않은
  값은 프로세스별 `mahanaim-N` 값으로 교체한다.
- response에는 같은 ID를 반환한다. 로그·metrics·외부 trace exporter는 이 값을
  correlation key로 사용한다.
- `/health` 성격의 liveness는 process reachability와 request/error/in-flight
  counters만 반환하며 readiness와 분리한다.
- readiness는 startup 이후 `200 ready`, shutdown 전후 또는 startup 전에는
  `503 not_ready`로 처리한다. load balancer는 readiness를 traffic gate로 쓴다.

## Timeout, cancellation, executor

- `requestTimeoutMs > 0`이면 deadline 초과 시 cooperative cancellation token을
  먼저 취소하고 `504 request_timeout`을 반환한다.
- Nim/taskpools는 임의 native thread를 안전하게 kill하지 않으므로, 강제 종료
  hook은 backend가 안전성을 보장할 때만 연결한다. 현재 기본 동작은 token 취소와
  진단 event이며, unsafe thread termination은 지원하지 않는다.
- `maxConcurrentJobs`를 초과하면 즉시 `503 executor_overloaded`를 반환한다.
  `queueWaitMs`가 있으면 그 시간까지만 기다리고 이후
  `503 executor_queue_timeout`으로 실패한다.
- 장애 복구 시에는 먼저 blocking detection과 executor counters를 확인하고,
  무한 queue나 무제한 retry로 트래픽을 흡수하지 않는다.

## Rate limit

- process-local `InMemoryRateLimitStore`는 단일 프로세스/테스트 용도다.
- remote store 오류는 fail-open하지 않고 bounded retry 후 `503`으로 반환한다.
  호출자는 retry storm을 막기 위해 작은 immediate retry 횟수만 사용한다.
- production Redis/Valkey adapter는 atomic counter, server-side TTL, server clock,
  eviction 정책을 제공해야 하며, 현재 저장소의 network RESP client는 미완료다.
  따라서 실제 distributed deployment에서는 해당 조건을 검증하기 전
  `InMemoryRateLimitStore`를 수평 확장 정책으로 사용하지 않는다.

## Background jobs

- job은 event loop에서 직접 실행하지 않고 `BackgroundJobQueue`를 통해 executor로
  보낸다.
- retry는 `maxAttempts`로 bounded하며 delay는 asynchronous sleep으로 처리한다.
  job 작성자는 side effect를 idempotent하게 만들거나 별도의 idempotency key를
  저장해야 한다.
- 현재 queue는 process memory 기반이므로 process crash 이후 job recovery를
  보장하지 않는다. durable queue adapter를 연결하기 전에는 중요한 작업을
  성공으로 간주하지 않는다.

## PostgreSQL live integration fixture

The optional `mahanaim/postgres_testing` module does not open a connection
unless all required credentials are supplied. Configure the live fixture with
`MAHANAIM_POSTGRES_HOST`, `MAHANAIM_POSTGRES_PORT`,
`MAHANAIM_POSTGRES_USER`, `MAHANAIM_POSTGRES_PASSWORD`, and
`MAHANAIM_POSTGRES_DATABASE`. The port defaults to `5432`; local installations
using another port must set it explicitly (for example `5433`).

The fixture wraps each operation in a transaction and rolls it back before the
connection is returned to the pool. `nimble postgresCheck` only compiles this
optional contract; a live isolation task must run in an environment that owns
the PostgreSQL credentials and database.

## Graceful shutdown

1. readiness를 false로 전환해 새 traffic을 차단한다.
2. server socket을 닫고 accept loop cancellation을 정상 종료로 분류한다.
3. shutdown hooks를 역순으로 실행한다.
4. durable queue/DB adapter를 연결한 배포에서는 in-flight transaction과 job
   acknowledgement를 별도 drain budget 안에서 완료한다.

현재 표준 TCP와 Windows stdlib Prologue adapter는 idempotent close를 검증했지만,
Beast live socket ownership fixture와 실제 external DB/queue drain은 아직 남아 있다.
