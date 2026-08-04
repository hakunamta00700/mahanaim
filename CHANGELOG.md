# Changelog

## Unreleased

- 계획 기반 framework contract, adapter 경계와 회귀 테스트를 계속 확장한다.
- SQLite adapter가 공통 `DatabaseResult`에 컬럼명과 선언 타입·runtime storage class 기반 typed scalar 및 NULL metadata를 제공하도록 확장했다.
- PostgreSQL 결과를 공통 `DatabaseResult`와 column metadata로 노출하고 libpq type OID 기반 typed scalar mapping을 추가했다.
- PostgreSQL live contract에 typed metadata, filtering, grouped aggregate, one-to-many relation, DDL rollback 검증과 `postgresLiveCheck` compile gate를 연결했다.
- `new` 생성기가 `.env.example`, 안전한 `.gitignore`, health route와 실제 dispatch 테스트를 포함한 starter project를 생성하도록 확장했다.
- 릴리스 지원 범위와 외부 live gate는 [`docs/support-policy.md`](docs/support-policy.md)를 따른다.

변경 사항은 사용자 영향, migration 필요 여부, 보안 기본값 변경 여부를 함께
기록한다.
