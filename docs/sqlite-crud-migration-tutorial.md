# SQLite CRUD와 migration 튜토리얼

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**대상:** Mahanaim에서 로컬 SQLite 모델을 처음 만드는 개발자.
**성숙도:** SQLite는 stable이며, PostgreSQL 전환은 [PostgreSQL 설정과 제한](postgresql.md)을 별도로 확인한다.
**실행 검증:** `nimble docsExamples` (`examples/sqlite_crud_migration.nim`)

이 튜토리얼은 빈 SQLite 데이터베이스에서 metadata를 선언하고 migration을 적용한
뒤, repository로 create/read/update/delete를 수행하고 migration을 되돌리는 가장 작은
완주 경로다. 예제는 in-memory SQLite를 사용하므로 자격 증명, 서버, 파일 정리가
필요 없다.

## 1. 실행 가능한 전체 예제

```powershell
nim c --path:src -r examples/sqlite_crud_migration.nim
```

성공하면 `sqlite-crud-migration-ok`을 출력한다. CI와 로컬의 공통 gate는 다음과 같다.

```powershell
nimble docsExamples
```

예제의 핵심은 다음 순서다.

1. `newModelMetadata`와 `newModelField`로 테이블과 필드를 선언한다.
2. `migrationFromMetadata(items, "001_items")`로 검토 가능한 migration을 만든다.
3. `executeMigrationCommand(..., parseMigrationCommand(["migrate"]))`로 적용한다.
4. `newDatabaseRepository`로 create, update, list, delete, find를 수행한다.
5. 예제 전용의 가역 migration을 `rollback`한다.

`migrationFromMetadata`는 선언을 읽어 자동으로 데이터를 삭제하지 않는다. migration을
review한 뒤 registry에 명시적으로 등록해야 한다. `ResourceRow`의 값도 SQL 문자열
연결이 아니라 metadata와 repository를 통해 전달한다.

## 2. 파일 기반 로컬 애플리케이션으로 옮기기

실제 프로젝트에서는 `newSqliteDatabaseAdapter()` 대신 소유권이 분명한 파일 경로를
열고, application shutdown hook에서 같은 adapter를 닫는다.

```nim
let adapter = newSqliteDatabaseAdapter("var/app.sqlite")
app.onShutdown(proc() {.gcsafe.} = adapter.close())
```

같은 migration 목록을 application과 CLI에 등록한다. 생성 프로젝트는 이 패턴을
`mahanaim db status|migrate|up|rollback|seed` 명령과 함께 제공한다. 명령의 입력,
종료 코드, 실패 원인은 [CLI 레퍼런스](cli-reference.md), registry 구성은
[Migration 가이드](migrations.md), connection/session 소유권은
[데이터베이스 연결](database-connections.md)을 따른다.

운영 데이터에서 `rollback`은 이 튜토리얼처럼 안전하다고 가정하면 안 된다. drop,
rename, type 변경은 백업과 복구 연습을 포함한 다중 릴리스 절차로 처리한다. migration
실패 시에는 새 SQL을 즉시 덮어쓰지 말고, `db status`와 적용 이력을 확인한 뒤
forward fix 또는 검증된 rollback을 선택한다.

## 3. 다음 단계

- 필드, index, relation 선언: [모델과 metadata](models-and-metadata.md)
- filter, pagination, aggregate: [Querying](querying.md)
- transaction, pool, request scope: [데이터베이스 연결](database-connections.md)
- PostgreSQL 환경과 live 검증: [PostgreSQL 설정과 제한](postgresql.md)
