# PostgreSQL 설정과 제한

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**마지막 검증:** `nimble docsCheck`

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.

**대상:** Mahanaim의 선택적 PostgreSQL adapter를 평가하거나 운영 환경에 연결하는 개발자.
**성숙도:** experimental. SQLite가 기본 stable backend다.
**검증:** `nimble postgresCheck`, `nimble postgresLiveCheck`, credential 환경의 `nimble postgresLive`

PostgreSQL adapter는 SQLite와 같은 metadata, migration, repository 계약을 사용하지만
database client, credential, connection pool, SQL dialect와 운영 증거는 애플리케이션이
소유한다. SQLite 예제가 통과해도 PostgreSQL 배포가 검증된 것은 아니다. 먼저
[SQLite CRUD와 migration 튜토리얼](sqlite-crud-migration-tutorial.md)로 로컬 경로를
완주한 다음 이 문서의 live gate를 별도로 실행한다.

## 1. 필요한 환경 변수

live fixture는 다음 값을 모두 받아야 실제 연결을 연다.

| 변수 | 필수 | 기본값/설명 |
| --- | --- | --- |
| `MAHANAIM_POSTGRES_HOST` | 아니오 | host; 프로젝트가 명시적으로 설정하는 것을 권장 |
| `MAHANAIM_POSTGRES_PORT` | 아니오 | `5432` |
| `MAHANAIM_POSTGRES_USER` | 예 | 연결 사용자 |
| `MAHANAIM_POSTGRES_PASSWORD` | 예 | 연결 비밀번호 |
| `MAHANAIM_POSTGRES_DATABASE` | 예 | disposable test database 이름 |

PowerShell에서 현재 세션에만 값을 설정하는 예시는 다음과 같다. 실제 비밀번호를
repository, 문서 예제, 로그에 기록하지 말고 secret manager 또는 CI secret을 사용한다.

```powershell
$env:MAHANAIM_POSTGRES_HOST = "127.0.0.1"
$env:MAHANAIM_POSTGRES_PORT = "5432"
$env:MAHANAIM_POSTGRES_USER = "mahanaim_test"
$env:MAHANAIM_POSTGRES_PASSWORD = "<secret-manager-value>"
$env:MAHANAIM_POSTGRES_DATABASE = "mahanaim_test"
nimble postgresLive
```

`postgresLive`는 user/password/database 중 하나라도 없으면 명시적인 skip을 출력한다.
그 skip은 로컬 개발에서 안전한 동작이지만, PostgreSQL이 release 범위라면 성공 증거가
아니다. credential이 있는 disposable database에서 성공 로그와 환경 범위를 release
record에 보관한다.

## 2. 단계별 검증과 실패 대응

1. `nimble postgresCheck`로 optional adapter surface를 compile한다. `libpq` 누락 또는
   링크 오류는 PostgreSQL client runtime 설치와 PATH/loader 설정을 확인한다.
2. `nimble postgresLiveCheck`로 live fixture source가 compile되는지 확인한다. 이 단계는
   database 연결을 열지 않는다.
3. disposable database를 지정한 뒤 `nimble postgresLive`를 실행한다. 이 gate는
   parameter binding, migration history/rollback, transaction isolation, repository CRUD와
   connection ownership을 실제 adapter로 검증한다.
4. 실패하면 schema나 production database를 수동으로 수정하기 전에 fixture의 host,
   port, credential, client runtime, server role 권한과 test database 격리를 확인한다.

일반적인 migration registry와 CLI 사용법은 [Migration 가이드](migrations.md)를,
session/pool lifecycle은 [데이터베이스 연결](database-connections.md)을 참조한다.

## 3. 지원 범위와 제한

| 범위 | 현재 계약 |
| --- | --- |
| dialect/repository/migration | PostgreSQL adapter contract와 optional live fixture로 검증 |
| isolation | `READ COMMITTED`, `REPEATABLE READ`, `SERIALIZABLE` |
| row locking | `FOR UPDATE`, `FOR SHARE` |
| production pool, TLS, failover, backup/restore | 애플리케이션·provider 운영 책임; 이 package의 live fixture가 보증하지 않음 |
| 다른 database backend | adapter extension 범위이며 PostgreSQL 증거로 추론하지 않음 |

라이브 fixture는 각 테스트 동작을 transaction으로 감싸 rollback하고 disposable schema를
사용하도록 설계되었다. 그 특성은 production backup, replication, connection timeout,
certificate rotation, migration window를 대체하지 않는다. 지원 수준과 OS/CI 경계는
[지원 매트릭스](support-matrix.md), 운영 점검은
[운영 가이드](operations-guide.md)를 기준으로 한다.
