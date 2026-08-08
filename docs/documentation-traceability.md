# 문서·검증 추적표

**책임 경계:** 프레임워크는 공개 API·CLI·검증 계약을 제공하며, 프로젝트는 조립·설정을, 외부 provider는 credential·비용·가용성과 live 증거를 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)가 유일한 maturity 기준이다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; 세부 target은 [지원 매트릭스](support-matrix.md)를 따른다.
**선행 조건:** 저장소 checkout과 Nim `>= 2.2.0`.
**대상 독자:** 기능을 추가·검토·릴리스하는 Mahanaim 사용자와 유지보수자.
**안정성 기준:** `stable`도 아래 gate를 통과한 범위만 의미하며 provider live 보장은 별도다.
**마지막 검증:** `nimble docsCheck`, `nimble docsExamples`, `nimble publicApiCheck`.
**관련 문서:** [공개 모듈 지도](api-reference/public-modules.md) · [CLI 레퍼런스](cli-reference.md) · [설정](configuration.md) · [알려진 제한](known-limitations.md)

이 표는 새 public API·CLI·환경 변수·기능이 추가될 때 같은 변경에서 갱신하는 release review의 단일 추적 지점이다. 공개 symbol은 [생성 API 레퍼런스](api-reference/README.md)와 공개 모듈 지도에서, CLI와 환경 변수는 각 reference에서 상세 기본값·실패 처리를 확인한다. `local/CI/live` 열은 실행 범위를 명시하며, credentialed live 증거가 없으면 기능은 experimental로 남는다.

| 기능 | API/CLI·설정 기준 | 사용자 가이드 | local/CI 실행 예제·테스트 | live/제한 |
| --- | --- | --- | --- | --- |
| `application-routing` | `core`, `router`, `application`; `mahanaim new` | [라우팅](routing.md) | `minimal_app.nim`; `nimble test` | 없음 |
| `dependency-injection` | `di`, `application` | [애플리케이션과 모듈](application-and-modules.md) | `plugin_extension.nim`; `nimble docsExamples` | 없음 |
| `typed-api-openapi` | `openapi`, `validation`; `openapi` CLI | [API 개발](api-development.md) | `api_artifacts.nim`; `nimble docsExamples` | browser/UI는 experimental |
| `sqlite-storage` | `sqlite_adapter`; migration CLI | [SQLite 튜토리얼](sqlite-crud-migration-tutorial.md) | `sqlite_crud_migration.nim`; `nimble test` | backup/rollback 문서화 |
| `postgresql-adapter` | `postgres_adapter`; `MAHANAIM_POSTGRES_*` | [PostgreSQL](postgresql.md) | `nimble postgresCheck` | credentialed `postgresLive` |
| `admin-forms` | `admin`, `forms`; admin CLI | [Admin](admin.md) | `admin_audit.nim`, `admin_templates.nim` | browser smoke evidence |
| `authentication-security` | `security`, `account_auth`; auth env | [인증](authentication.md) | `nimble test` | identity provider live gate |
| `email-notifications` | `email`, `flash`; SMTP env | [알림·신디케이션](email-and-notifications.md) | `nimble test` | disposable SMTP evidence |
| `background-jobs` | `jobs`, `durable_jobs`; jobs CLI | [백그라운드 작업](background-jobs.md) | `jobs_realtime_channels.nim` | queue provider evidence |
| `http-transport` | adapters; `MAHANAIM_HTTPS_URL` | [배포](deployment.md) | `nimble beastLive` | staging TLS evidence |
| `storage-cache-rate-limit` | `storage`, `redis_resp`; provider env | [캐시](cache.md) | `local_storage.nim`; `nimble redisLive` | S3 credentialed evidence |
| `realtime-events` | `channels`, `redis_channels` | [채널 레이어](channel-layers.md) | `jobs_realtime_channels.nim`; `nimble test` | Redis provider evidence |
| `observability-testing-cli` | `observability`, `cli`; app env | [관측성](observability.md) | `nimble verify`; `nimble docsCheck` | deployment telemetry ownership |

검토자는 표의 각 행에서 API/CLI·설정, 가이드, 실행 증거, provider 제한을 모두 확인한 뒤에만 [지원 매트릭스](support-matrix.md)의 maturity를 변경한다.
