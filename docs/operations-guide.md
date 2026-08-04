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

## Password hashing

`newArgon2idPasswordHasher`는 PHC encoded Argon2id hash를 생성하고 저장된
cost parameter를 읽어 `verifyAndRehash`로 점진적 cost rotation을 수행한다.
메모리·반복·parallelism은 생성자에서 bounded policy로 검증해야 하며, 운영 배포는
실제 hardware에서 login latency와 concurrent memory 사용량을 benchmark한 뒤 값을
선택한다. `newBcryptPasswordHasher`는 Nim의 maintained pure implementation을
통해 `$2b$` hash를 생성하고 `$2a$`·`$2b$`·`$2y$` 저장 hash를 검증하며, 동일한
`PasswordHasher` 계약과 `verifyAndRehash` rotation을 사용한다. bcrypt의
`workFactor`도 배포 호스트에서 실측해야 하고, PBKDF2는 호환성 reference adapter로
유지한다.

## Template extensions

Template 확장은 `engine.registerTag("name", callback)`으로 등록하며 `{% tag name
arg %}` 문법으로 호출한다. tag 결과도 변수와 동일하게 HTML escaping을 거치므로
신뢰할 수 없는 값을 반환하는 helper가 raw HTML 주입구가 되지 않는다. 조건부 출력은
`{% if key %}...{% else %}...{% endif %}`를 사용하며 빈 문자열·`false`·`no`·`off`·`0`은
false로 처리된다.

날짜·시간 표시에서 DST가 필요한 경우 `newIanaLocaleFormatPolicy("en-US",
"America/New_York")`처럼 IANA 이름을 application 설정 단계에서 resolve한다. 잘못된
zone은 startup에서 거부되며, formatter는 UTC instant를 기준으로 해당 시점의
offset을 적용한다. 고정 offset은 DST가 필요하지 않은 deterministic 작업에만
사용한다.

Argon2와 bcrypt 정책 측정은 `nimble passwordBenchmark`로 시작할 수 있다. 세부 값을 바꾸려면
생성된 `benchmarks/password_hash_benchmark.exe`(또는 해당 플랫폼 실행 파일)에
Argon2는 `--algorithm=argon2id --memory-kib`, `--iterations`, `--threads`,
`--derived-bytes`, bcrypt는 `--algorithm=bcrypt --work-factor`, 공통으로
`--samples`를 명시해 hash/verify 평균 latency를 기록한다. 동시 로그인 부하에서
메모리 사용량도 별도로 확인한 뒤 정책 값을 확정한다. benchmark 기본값은 adapter
기본 policy를 반영하지만 보안·성능 보증값은 아니다.

## Rate limit

- process-local `InMemoryRateLimitStore`는 단일 프로세스/테스트 용도다.
- remote store 오류는 fail-open하지 않고 bounded retry 후 `503`으로 반환한다.
  호출자는 retry storm을 막기 위해 작은 immediate retry 횟수만 사용한다.
- RESP client의 `stats()` snapshot으로 requests, successes, failures,
  connections, reconnects를 metrics sink에 연결한다. 이 수치는 정책 판단이
  아니라 장애 관찰용이며, secret/key/payload를 포함하지 않는다.
- production Redis/Valkey adapter는 atomic counter, server-side TTL, server clock,
  eviction 정책을 제공해야 한다. `inspectRedisCompatibility(client)`는 읽기 전용
  `INFO server`, `CONFIG GET maxmemory-policy/maxmemory`, `COMMAND INFO`를 실행해
  vendor/version, 필수 RESP command, maxmemory 및 bounded eviction 여부를 보고한다. 현재 저장소는 RESP client,
  socket timeout, bounded retry와 loopback 검증을 제공하지만 실제 Redis/Valkey
  버전 matrix와 eviction 운영 검증은 별도 배포 gate다. 해당 조건을 검증하기 전
  `InMemoryRateLimitStore`를 수평 확장 정책으로 사용하지 않는다.

`InMemoryRateLimitStore`는 monotonic clock으로 window TTL을 계산하고 매 요청
시 만료 key를 정리한다. `newInMemoryRateLimitStore(maxKeys)`의 bound를 넘으면
가장 오래된 active window를 제거하므로 local/test 환경에서도 attacker-controlled
key cardinality가 메모리를 무한히 늘리지 않는다. Redis/Valkey 운영에서는 별도의
  `maxmemory`와 eviction policy를 설정하고 live gate에서 확인해야 한다.

CI 또는 Linux 환경에서는 `MAHANAIM_REDIS_HOST`와 `MAHANAIM_REDIS_PORT`를 설정한 뒤
`nimble redisLive`를 실행한다. 이 gate는 PING, compatibility probe와 server-side
TTL을 실제 socket에서 확인한다. Windows Docker NAT에서 native Nim socket이
timeout되는 경우에는 해당 실행을 성공 증거로 기록하지 말고 Linux runner 또는
명시적으로 접근 가능한 Redis/Valkey service에서 재실행한다.

2026-08-05 Linux Nim 2.2.4 matrix 결과:

| 서비스 이미지 | 실제 버전 | 설정 | 결과 |
| --- | --- | --- | --- |
| `redis:7.2-alpine` | Redis 7.2.15 | `maxmemory=16mb`, `allkeys-lru` | PING/필수 명령/eviction/TTL 통과 |
| `valkey/valkey:8-alpine` | Valkey 8.1.9 | `maxmemory=16mb`, `allkeys-lru` | PING/필수 명령/eviction/TTL 통과 |

이 matrix는 Redis/Valkey rate-limit adapter 범위를 증명한다. S3 signing/retry와
별도 cache eviction 부하·장애 운영 검증은 해당 storage 운영 gate에 남아 있다.

## HTTPS reverse-proxy 배포 점검표

TLS 종료 지점과 애플리케이션의 책임을 분리한다. Mahanaim은 HTTP request를
처리하는 프레임워크이고, 인증서 발급·갱신과 외부 TLS wire는 reverse proxy 또는
ingress가 소유한다. 다음 항목은 배포 전 반드시 확인한다.

애플리케이션이 HTTPS를 강제해야 할 때는 `SecurityPolicy.requireHttps = true`를
설정한다. `X-Forwarded-Proto`와 `X-Forwarded-Host`는 `Request.remoteAddress`가
`SecurityPolicy.trustedProxies`에 정확히 포함될 때만 반영된다. proxy가 직접 peer
주소를 전달하지 않는 adapter에서는 forwarded header를 신뢰하지 않는다.

- [ ] 외부 listener가 HTTP를 HTTPS로 redirect하고, TLS 1.2 이상과 운영 도메인
  인증서 체인을 사용한다.
- [ ] reverse proxy가 upstream 연결을 신뢰할 수 있는 private network 또는
  mTLS로 제한하고, 임의의 `X-Forwarded-*` 헤더를 외부에서 그대로 통과시키지
  않는다.
- [ ] proxy가 `Host`를 검증된 public host로 전달하고 애플리케이션의
  `allowedHosts`를 명시적으로 설정한다.
- [ ] HTTPS에서 발급되는 session/CSRF cookie의 `Secure`, `HttpOnly`, 적절한
  `SameSite`, path/domain을 확인한다. 개발용 HTTP에서는 secure cookie를
  의도적으로 꺼야 하므로 환경별 설정을 분리한다.
- [ ] proxy가 request body, header, idle/read/write timeout을 애플리케이션의
  `maxBodyBytes`와 `requestTimeoutMs`보다 느슨하지 않게 설정한다.
- [ ] `/health`는 liveness, readiness endpoint는 traffic gate로 분리하고,
  readiness가 실패한 instance로 연결을 보내지 않도록 한다.
- [ ] 원본 client IP가 필요한 경우 신뢰하는 proxy 주소와 access-log redaction을
  명시한다. 애플리케이션이 검증하지 않은 forwarded client IP를 rate limit key나
  authorization 판단에 직접 사용하지 않는다.
- [ ] HSTS, CSP, frame/referrer 정책과 CORS allow-list를 실제 public origin에
  맞춰 검증한다.
- [ ] TLS termination 이후의 redirect loop, websocket upgrade, SSE streaming,
  chunked response, graceful shutdown을 실제 staging endpoint에서 wire 테스트한다.

현재 저장소의 automated contract test와 Linux CI HTTPS gate 및 `check`는 secure cookie/header,
trusted proxy scheme/host, HTTPS rejection, 공개 host 고정 warning, body limit,
timeout, health/readiness와 loopback HTTP/SSE/WebSocket을 검증한다. 실제
인증서, proxy hop, TLS handshake와 운영 ingress 설정은 배포 환경에서 수행해야 한다.

재현 가능한 로컬 wire gate는 Docker nginx와 Linux Nim upstream을 함께
사용한다. upstream 컨테이너는 cold Docker cache에서 lockfile 의존성을
설치하고 컴파일할 수 있도록 bounded readiness window를 사용한다. Windows
Docker 환경에서 다음 명령은 ephemeral self-signed
certificate를 만들고 TLS 1.2/1.3 handshake, reverse-proxy hop, trusted
forwarded scheme/host, `Secure`·`HttpOnly` cookie를 실제 HTTPS client로
검증한 뒤 모든 컨테이너와 인증서를 정리한다.

```powershell
powershell -NoProfile -Command "& '.\tests\run_https_wire.ps1'"
```

외부 staging endpoint는 인증서 검증을 기본 활성화한 별도 gate로 실행한다.
`MAHANAIM_HTTPS_INSECURE=1`은 self-signed 로컬 fixture에서만 허용한다.

```powershell
$env:MAHANAIM_HTTPS_URL = 'https://public.example/wire'
nimble httpsLiveCheck
nimble httpsLive
```

2026-08-05 로컬 wire 결과: Docker nginx 1.27.5, Nim/Linux 2.2.4
upstream에서 `HTTPS reverse-proxy live contract passed`. 운영 staging의
공인 인증서 체인, HTTP→HTTPS redirect, 갱신 자동화와 외부 DNS는 여전히
배포 환경에서 별도로 확인해야 한다.

## Background jobs

- job은 event loop에서 직접 실행하지 않고 `BackgroundJobQueue`를 통해 executor로
  보낸다.
- retry는 `maxAttempts`로 bounded하며 delay는 asynchronous sleep으로 처리한다.
  job 작성자는 side effect를 idempotent하게 만들거나 별도의 idempotency key를
  저장해야 한다.
- 현재 queue는 process memory 기반이므로 process crash 이후 job recovery를
  보장하지 않는다. durable queue adapter를 연결하기 전에는 중요한 작업을
  성공으로 간주하지 않는다.
- `enqueueIdempotent`는 명시적 key를 `IdempotencyStore`에 claim하고 성공 시
  유지하며, 실패 시 release한다. 기본 in-memory store는 프로세스 재시작 후
  상태를 보존하지 않으므로 durable persistence의 대체가 아니다. 재시작 후
  key 상태가 필요한 단일 writer 환경은 append-only `FileIdempotencyStore`를,
  여러 connection/process가 공유하는 SQLite 환경은 `SqliteIdempotencyStore`를
  사용할 수 있다. durable job payload는 `SqliteDurableJobStore`의 named kind와
  opaque payload로 저장하며, process restart 시 `recoverProcessing()`으로
  미완료 claim을 pending으로 되돌린다. `DurableJobRegistry`가 named kind를
  handler에 연결하고 기존 bounded executor를 사용하며, 외부 queue recovery는
  별도 adapter가 담당한다.

## External durable queue adapters

Use `newExternalDurableJobStore` to bridge an application-owned queue client to
the framework's enqueue/claim/complete/release/recover/close contract. The
callback bridge deliberately does not prescribe serialization, visibility
timeouts, acknowledgement semantics, or provider retries; those policies must
be documented and tested by the concrete queue adapter before deployment.

## PostgreSQL live integration fixture

The optional `mahanaim/postgres_testing` module does not open a connection
unless all required credentials are supplied. Configure the live fixture with
`MAHANAIM_POSTGRES_HOST`, `MAHANAIM_POSTGRES_PORT`,
`MAHANAIM_POSTGRES_USER`, `MAHANAIM_POSTGRES_PASSWORD`, and
`MAHANAIM_POSTGRES_DATABASE`. The port defaults to `5432`; local installations
using another port must set it explicitly (for example `5433`).

The fixture wraps each operation in a transaction and rolls it back before the
connection is returned to the pool. `nimble postgresCheck` compiles the
optional adapter contract, while `nimble postgresLive` executes the real
parameterized query and transaction-isolation contract when credentials are
available; otherwise it reports an explicit skip.

Embedding tests can call `newPostgresTestFixtureFromEnv()` to obtain the same
rollback fixture without duplicating environment parsing. A missing value
returns `none`; a live/integration suite should treat that result as an
explicit skip, while a release gate should fail if PostgreSQL credentials are
required but absent.

The PostgreSQL 16 live contract was executed on 2026-08-05 with Nim 2.2.4.
It passed migration up/idempotency/rollback, serializable transaction setup,
repository filtering/aggregate/one-to-many loading, typed scalar metadata,
and the custom `money` codec over a PostgreSQL `jsonb` result (OID 3802).
The live command prints `PostgreSQL live contract passed`; this evidence covers
the database adapter contract, not a production connection pool or live HTTP
server deployment.

### Database capability contract

The framework exposes backend capability data instead of silently emulating a
feature with different semantics. The current contract is:

| Backend | Transactions | Savepoints | Isolation levels | Row locks |
| --- | --- | --- | --- | --- |
| SQLite | supported | supported | unsupported by adapter contract | unsupported |
| PostgreSQL | supported | supported | `READ COMMITTED`, `REPEATABLE READ`, `SERIALIZABLE` | `FOR UPDATE`/`FOR SHARE` |

SQLite unsupported isolation and row-lock requests fail explicitly. The
PostgreSQL live fixture applies `SERIALIZABLE` inside its transaction and
exercises migration command status/up/idempotency/history/rollback. The matrix
is also pinned by the common unit contract in `tests/test_core.nim`.

The same `postgresLive` contract opens real libpq adapters through the
framework-owned `DatabaseConnectionPool` and `DatabaseSession`. It verifies
serializable session setup, committed data visibility on a reused connection,
automatic rollback on session close, and active-connection cleanup after pool
shutdown. It also serves real HTTP, SSE, and WebSocket requests through
`NetworkServer`, where application dispatch and protocol ownership are tested
over the wire. The WebSocket client reads the server close frame before
closing its socket, proving graceful ownership handoff.

## Admin CLI inspector

`runAdminCli(registry, ["resources"])` prints only registered resource names and
prefixes. `runAdminCli(registry, ["audit"])` prints only append-only audit
identity fields. The inspector is intentionally read-only and receives an
explicit `AdminRegistry`; it does not create a second authorization or database
lifecycle. Destructive or durable admin commands remain application-owned
commands with their own authorization and transaction policy.

## Durable job CLI

An application can call `configureDurableJobs(store, registry)` before startup.
`jobs recover` moves interrupted `processing` records back to `pending`, while
`jobs run [max]` claims at most the requested number of records through the
application's bounded executor. Persisted `kind` values never load code dynamically; the
application must register each handler explicitly. The command is intended for
operator-controlled deployment or drain workflows, and an application should
wrap it with its own authorization and release procedure when exposed by a
larger control plane.

## Prometheus metrics

Expose `metricsResponse(app.observability)` from an application-owned `GET /metrics`
route. The core exporter emits only request/error counters, in-flight gauge, and
readiness gauge; it never includes request IDs, trace IDs, secrets, cache keys, or
payloads. Prometheus text exposition is vendor-neutral. Logue and OpenTelemetry
integrations should consume the existing `RequestEventSink`, `StructuredLogSink`,
and W3C trace propagation boundaries in an application-owned adapter.

## Graceful shutdown

1. readiness를 false로 전환해 새 traffic을 차단한다.
2. server socket을 닫고 accept loop cancellation을 정상 종료로 분류한다.
3. shutdown hooks를 역순으로 실행한다.
4. durable queue/DB adapter를 연결한 배포에서는 in-flight transaction과 job
   acknowledgement를 별도 drain budget 안에서 완료한다.

현재 표준 TCP와 Windows stdlib Prologue adapter는 idempotent close를 검증했지만,
Beast live socket ownership fixture는 Linux에서 `beastLiveCheck`와 `beastLive`로 handshake, frame, handler finalization, close를 검증한다. external DB/queue drain은 별도 live 증거가 필요하다.
