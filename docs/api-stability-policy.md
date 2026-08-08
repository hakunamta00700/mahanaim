# API stability and release policy

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

이 문서는 Mahanaim core의 공개 API와 adapter 경계에 적용하는 호환성
정책이다. 설치 가능한 버전과 최소 dependency는 [`mahanaim.nimble`](../mahanaim.nimble)에
있고, OS·Nim·database 지원 범위는 [`support-matrix.md`](support-matrix.md)에
있다. 두 문서가 다르면 release를 만들기 전에 manifest를 source of truth로
맞춘다.

## Semantic versioning

Mahanaim은 `MAJOR.MINOR.PATCH` 형식의 Semantic versioning을 따른다.

- `PATCH`: public behavior를 유지하는 bug/security fix, 문서와 내부 최적화.
- `MINOR`: 기존 호출을 깨지 않는 새 core API, adapter capability, CLI 명령.
- `MAJOR`: public type·procedure signature, response/error semantics, lifecycle
  invariant 또는 지원 dependency를 호환되지 않게 변경하는 경우.

현재 `0.1.0`은 framework가 아직 `1.0.0` 이전임을 의미한다. 그렇더라도 이미
공개된 `Request`, `Response`, `Application`, route/middleware, metadata,
serializer와 adapter protocol은 의도적으로 안정된 계약으로 취급하고, breaking
change는 migration note 없이 병합하지 않는다.

## Compatibility ownership

core와 adapter의 책임을 분리한다.

| 영역 | 기준 | release evidence |
| --- | --- | --- |
| Nim/compiler | manifest의 최소 Nim과 CI matrix의 baseline `2.2.4` | `nimble check`, OS/Nim matrix |
| package dependency | `mahanaim.nimble`의 minimum version과 `nimble.lock` checksum | `nimble lockCheck`, clean install |
| HTTP adapter | core contract와 Prologue `0.6.8` compatibility boundary | compile/contract/live adapter gate |
| database | SQLite 기본 backend와 PostgreSQL adapter capability | unit contract 및 PostgreSQL live gate |
| optional provider | Redis/Valkey, Beast/httpx, S3 또는 외부 ORM | adapter contract와 application-owned live evidence |

adapter가 지원하지 않는 capability는 조용히 fallback하지 않고 명시적으로
`unsupported` 오류 또는 capability report로 노출한다. provider의 server version,
TLS credential, signing, rollout 상태를 core API 안정성의 증거로 간주하지 않는다.

## API maturity labels

문서와 changelog에서 기능 성숙도를 다음 label로 표시한다.

- `experimental`: API shape와 capability가 바뀔 수 있다. production contract로
  의존하지 말고 upgrade 시 migration note를 확인한다.
- `stable`: core contract, regression test와 문서가 함께 유지된다. 같은 major
  범위에서 호환성을 보장한다.
- `deprecated`: 대체 API가 존재하며 현재 release에서는 동작하지만 다음 major에서
  제거될 수 있다. 호출 지점과 제거 예정 버전을 changelog에 남긴다.

label은 함수 이름만으로 추측하지 않고 public API 문서, implementation plan과
changelog에 같은 이름으로 기록한다.

## API versioning

버전이 공존해야 하는 HTTP API는 `addVersionedDocumentedRoute` 또는
`addTypedVersionedDocumentedRoute`로 선언한다. `apiVersionUrl`은
`/v{version}` 경로를 사용하고, `apiVersionHeader`는 `Accept`의
`version={version}` parameter를 사용한다. 지원하지 않는 header version은
`406`과 `Vary: Accept`를 반환한다.

각 version은 별도의 `documentForVersion` OpenAPI document와
`typescriptClientForVersion` artifact를 생성한다. deprecated version은
operation의 `deprecated` 및 `x-deprecation-message` metadata에 남겨
클라이언트와 릴리스 노트가 동일한 전환 정보를 사용할 수 있게 한다.

## Deprecation and migration guide

deprecated API를 추가할 때는 한 변경에 다음 네 가지를 포함한다.

1. 기존 호출을 설명하는 regression test와 새 API를 사용하는 test를 함께 둔다.
2. Nim compiler warning 또는 명시적 runtime/configuration warning을 제공한다.
3. `docs/`에 before/after 예제와 data/config migration 순서를 기록한다.
4. 제거 예정 major 또는 최소 deprecation 기간을 `CHANGELOG.md`에 기록한다.

새 API가 기존 API와 의미가 다르면 이름만 바꾸지 말고 adapter bridge나 explicit
conversion을 제공한다. 특히 request lifecycle, transaction, security default와
serialization field exposure의 변화는 patch release에 포함하지 않는다.

## Security release

보안 수정은 일반 기능 변경과 분리해 관리한다.

- `CHANGELOG.md`에 영향 범위, 영향받는 버전, 수정 버전과 upgrade action을 별도
  항목으로 기록한다.
- secret, token, cookie, credential과 exploit payload를 commit message·log·fixture에
  포함하지 않는다.
- 보안 수정은 성공 경로보다 bypass, malformed input, unauthorized access 회귀
  테스트를 먼저 추가한다.
- dependency security fix는 manifest와 lockfile을 같은 변경에서 갱신하고
  `nimble lockCheck`를 통과시킨다.

## Release checklist

```text
nimble test
nimble verify
nimble check
nimble docsCheck
git diff --check
```

로컬 게이트가 통과해도 실제 GitHub OS runner, release artifact upload, staging
TLS와 provider live evidence를 대신하지 않는다. 그 결과는 support matrix와
release artifact에 별도로 기록하고, 증거가 없으면 기능을 `stable`로 승격하지
않는다.
