# Mahanaim 지원 정책

이 문서는 현재 저장소가 검증하는 지원 범위와 릴리스 판단 기준을 고정한다.
검증되지 않은 조합은 호환될 가능성이 있어도 지원 대상으로 표시하지 않는다.

## 현재 기준

- Nim 최소 버전: `2.2.4` 기준으로 검증한다.
- 기본 CI OS: Linux와 Windows.
- 기본 HTTP 의존성: Prologue `0.6.8` 및 lockfile에 기록된 의존성 집합.
- 기본 데이터 backend: SQLite.
- Windows runner의 PostgreSQL adapter compile/test surface는 PostgreSQL client
  runtime(`libpq.dll`)을 CI에서 명시적으로 설치한 뒤 검증한다. live database
  연결은 별도의 PostgreSQL service gate에서만 수행한다.
- PostgreSQL, Redis/Valkey, Beast/httpx, HTTPS reverse proxy는 별도 live gate가
  통과된 환경에서만 운영 지원으로 승격한다.

## 릴리스 체크리스트

- [ ] 지원 Nim/OS 조합에서 `test`, `check`, `verify`, `build`가 통과했다.
- [ ] `nimble.lock` 변경을 검토하고 재현 가능한 dependency 설치를 확인했다.
- [ ] secure cookie, host/CORS, body limit, timeout, CSRF와 rate-limit 기본값을
  보안 검토했다.
- [ ] PostgreSQL/Redis/Valkey/Beast/HTTPS가 릴리스 대상이면 각 live gate의
  성공 로그와 환경을 보관했다.
- [ ] 사용자 영향이 있는 변경을 `CHANGELOG.md`에 기록했다.
- [ ] `plan.md`와 [Definition of Done](definition-of-done.md)의 상태가 실제
  검증 범위와 일치한다.

## 버전과 호환성

Nim 또는 주요 adapter의 지원 범위를 변경할 때는 이 문서, CI matrix,
lockfile과 변경 로그를 같은 변경 단위에서 갱신한다. 외부 adapter의 오류나
운영 정책을 로컬 unit test 통과만으로 지원 완료로 표시하지 않는다.
