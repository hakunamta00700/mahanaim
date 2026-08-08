# 지원 런타임과 artifact 무결성

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

## 현재 기준

| 축 | 기준 | 검증 방법 |
| --- | --- | --- |
| Nim | `>= 2.2.0` (개발·CI 기준 `2.2.4`) | `validateRuntimeSupport`와 manifest |
| Windows | stdlib HTTP/Prologue transport | Windows native socket smoke test |
| Linux | stdlib HTTP와 Beast/httpx adapter 경계 | Linux CI와 optional live fixture |
| macOS | backend-neutral core 및 stdlib adapter 목표 | release matrix에서 별도 실행 |
| Dependencies | `nimble.lock` revision/checksum 고정 | `nimble install --depsOnly` |

지원 OS는 core 계약과 adapter별 live fixture의 범위를 분리해 관리한다.
플랫폼별 소켓 ownership이나 C runtime 차이를 공통 unit test의 성공만으로
추론하지 않는다.

## 기능 성숙도와 릴리스 증거

아래 표는 현재 배포본에 포함되는 모든 first-party 기능의 단일 성숙도
목록이다. `stable`은 표에 적힌 로컬·CI 증거를 모두 통과한 공개 계약이고,
`experimental`은 API 또는 실제 provider 운영 증거가 더 필요한 기능이다.
`deprecated` 기능은 대체 API와 제거 예정 버전을 changelog에 함께 기록한다.
각 행의 `evidence`는 CI에서 실행할 명령 또는 사람이 보관할 live evidence를
명시한다. 따라서 문서에 이름만 있고 검증 경계가 없는 기능은 지원으로
승격할 수 없다.

| feature | maturity | supported targets | evidence |
| --- | --- | --- | --- |
| application-routing | stable | Nim 2.2.4; Windows/Linux/macOS | `nimble test`, `nimble publicApiCheck` |
| dependency-injection | stable | Nim 2.2.4; Windows/Linux/macOS | `nimble test`, `nimble docsExamples` |
| typed-api-openapi | experimental | Nim 2.2.4; Windows/Linux/macOS | `nimble test`, `nimble docsExamples` |
| sqlite-storage | stable | SQLite; Windows/Linux/macOS | `nimble test` |
| postgresql-adapter | experimental | PostgreSQL 16; Linux CI, Windows/macOS compile | `nimble postgresCheck`, `nimble postgresLive` |
| admin-forms | experimental | SQLite; Windows/Linux/macOS | `nimble test`, browser smoke evidence |
| authentication-security | experimental | Nim 2.2.4; Windows/Linux/macOS | `nimble test`, provider contract fixture |
| email-notifications | experimental | callback transport; Windows/Linux/macOS | `nimble test`, disposable SMTP wire evidence |
| background-jobs | experimental | SQLite durable store; Windows/Linux/macOS | `nimble test`, queue provider live evidence |
| http-transport | experimental | Prologue; httpx/Beast on Linux | `nimble httpxTest`, `nimble beastLive` |
| storage-cache-rate-limit | experimental | Redis 7.2/Valkey 8.1; S3-compatible callback | `nimble redisLive`, credentialed S3 evidence |
| realtime-events | experimental | loopback/WebSocket; Redis channel layer | `nimble test`, WebSocket wire evidence |
| observability-testing-cli | stable | Nim 2.2.4; Windows/Linux/macOS | `nimble test`, `nimble verify` |

이 표의 `feature`, `maturity`, `supported targets`, `evidence` 열과 모든
first-party feature 행은 `tests/test_docs_contract.nim`에서 검증한다.
새 first-party 기능은 같은 변경에서 이 표와 해당 CI/live gate를 추가해야 한다.

## 기능 문서 연결표

모든 first-party 기능은 아래 사용자 문서 시작점을 가진다. 성숙도는 위 표가
유일한 기준이며, 가이드가 있다고 experimental 기능이 stable로 승격되는 것은
아니다.

| feature | 사용자 문서 |
| --- | --- |
| `application-routing` | [라우팅](routing.md), [요청과 검증](requests-and-validation.md), [응답과 콘텐츠 협상](responses-and-negotiation.md) |
| `dependency-injection` | [애플리케이션과 모듈](application-and-modules.md), [애플리케이션 모듈](application-modules.md) |
| `typed-api-openapi` | [API 개발](api-development.md), [OpenAPI](openapi.md), [API 보안](api-security.md) |
| `sqlite-storage` | [모델 메타데이터](models-and-metadata.md), [migration](migrations.md), [데이터베이스 연결](database-connections.md) |
| `postgresql-adapter` | [migration](migrations.md), [데이터베이스 연결](database-connections.md), [알려진 제한](known-limitations.md) |
| `admin-forms` | [Admin](admin.md), [Admin 운영](admin-operations.md), [Admin 템플릿 커스터마이징](admin-template-customization.md) |
| `authentication-security` | [인증](authentication.md), [권한](authorization.md), [보안](security.md) |
| `email-notifications` | [알림과 이메일](email-and-notifications.md), [알려진 제한](known-limitations.md) |
| `background-jobs` | [백그라운드 작업](background-jobs.md), [외부 어댑터](external-adapters.md) |
| `http-transport` | [배포](deployment.md), [테스트](testing.md), [알려진 제한](known-limitations.md) |
| `storage-cache-rate-limit` | [저장소](storage.md), [캐시](cache.md), [운영 가이드](operations-guide.md) |
| `realtime-events` | [WebSocket](websocket.md), [SSE](sse.md), [채널 레이어](channel-layers.md) |
| `observability-testing-cli` | [관측성](observability.md), [테스트](testing.md), [CLI 레퍼런스](cli-reference.md) |

## Experimental feature reading map

Experimental rows have a local contract but still require the named provider,
browser, transport, or live deployment evidence. Read the corresponding guide
before treating them as production-ready:

- `typed-api-openapi`: [API development](api-development.md), [OpenAPI](openapi.md), and [known limitations](known-limitations.md).
- `postgresql-adapter`: [migrations](migrations.md), [database connections](database-connections.md), and [known limitations](known-limitations.md).
- `admin-forms`: [Admin](admin.md), [Admin operations](admin-operations.md), and [Admin template customization](admin-template-customization.md).
- `authentication-security`: [authentication](authentication.md), [security](security.md), and [security deployment checklist](security-deployment-checklist.md).
- `email-notifications`: [email and notifications](email-and-notifications.md) and [known limitations](known-limitations.md).
- `background-jobs`: [background jobs](background-jobs.md) and [external adapters](external-adapters.md).
- `http-transport`: [deployment](deployment.md), [testing](testing.md), and [known limitations](known-limitations.md).
- `storage-cache-rate-limit`: [storage](storage.md), [cache](cache.md), and [operations guide](operations-guide.md).
- `realtime-events`: [WebSockets](websocket.md), [SSE](sse.md), and [channel layers](channel-layers.md).

## macOS release runner baseline (2026-08-05)

- [x] GitHub Actions cross-platform matrix에 `macos-latest`와 Nim 2.2.4 runner를 선언했다.
- [x] macOS는 Homebrew `libpq` runtime을 별도 설치하고 `shasum -a 256`으로 release candidate checksum을 생성·검증한다.
- [ ] 실제 GitHub macOS runner의 test·verify·check·build 성공 로그와 artifact 업로드 증거는 외부 CI 실행에서 수집한다.

## Release artifact manifest

Release automation은 다음과 같은 `ReleaseArtifact` 항목을 생성한다.

```text
path=dist/mahanaim-0.1.0-linux-amd64.tar.gz
sha256=<64 hexadecimal characters>
```

`sha256File`은 파일 bytes를 그대로 읽고, `verifyArtifactChecksum`은 누락·형식
오류·불일치를 모두 실패로 처리한다. 따라서 Windows 줄바꿈 변환이나 경로
오류가 checksum 검증을 우회하지 못한다.

`collectReleaseArtifacts`와 `writeArtifactManifestForFiles`는 release runner가
파일 목록만 넘겨도 checksum 계산·중복 검사·path 정렬을 공통 API로 수행하게
하며, shell별 checksum 구현이 manifest 형식을 따로 재구성하지 않도록 한다.

## 운영 원칙

- [ ] 각 release artifact를 Linux·Windows·macOS target에서 생성한다.
- [ ] 생성 직후 SHA-256 manifest를 저장하고 배포 전에 검증한다.
- [ ] `nimble.lock` 변경은 dependency review와 함께 수행한다.
- [ ] 지원 matrix 밖의 OS/Nim 조합은 experimental로 표시하고 stable release에 포함하지 않는다.
- [x] Beast/httpx live fixture와 `beastLiveCheck`/`beastLive` gate를 Linux CI에 연결해 httpx/asyncdispatch ownership handoff와 WebSocket wire를 검증한다. macOS release runner 연결은 별도 matrix 확장 범위다.

CI release job은 `nimble releaseManifest`와 `MAHANAIM_RELEASE_ARTIFACTS`를
사용해 `collectReleaseArtifacts`에서 실제 bytes checksum을 계산하고,
`writeArtifactManifestForFiles`로 path 순서의 deterministic manifest를 만든다.
`renderArtifactManifest`/`validateReleaseArtifacts`는 embedding release script가
동일한 metadata·파일 검증 contract를 재사용할 수 있게 유지한다.
