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

## Evidence promotion policy

`docs/support-matrix.md`의 기능별 행은 다음 조건을 만족할 때만
`experimental`에서 `stable`로 바꾼다.

1. 지원 Nim/OS/backend 조합과 실행할 검증 명령을 같은 행에 기록한다.
2. 네트워크 provider는 단위 테스트 외에 credentialed 또는 disposable live
   fixture의 성공 로그·환경 버전을 release artifact에 보관한다.
3. CI는 모든 지원 OS에서 release artifact manifest를 생성·업로드하고,
   provider가 필요한 기능은 해당 live gate를 실행하거나 명시적 skip 사유를
   남긴다.
4. deprecation은 대체 API, 제거 예정 major, migration 안내를 changelog와
   API stability policy에 함께 기록한다.

외부 증거가 누락되면 안정성 label을 승격하지 않는다. 예를 들어 로컬 Redis
fixture의 성공은 S3 credential lifecycle 또는 production queue drain의
운영 증거를 대신하지 않는다.

## 릴리스 체크리스트

- [ ] 지원 Nim/OS 조합에서 `test`, `check`, `verify`, `build`가 통과했다.
- [x] `nimble.lock` 변경을 검토하고 `validateDependencyLock`·`nimble lockCheck`로 metadata와 checksum shape를 확인한다. clean runner의 실제 dependency 재설치 증거는 CI matrix에서 별도로 확인한다.
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
