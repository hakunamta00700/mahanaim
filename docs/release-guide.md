# 릴리스 가이드

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**대상:** 프레임워크 또는 애플리케이션 릴리스를 판정하는 유지보수자
**로컬 검증:** `nimble verify`, 릴리스 CI, artifact manifest 검증

버전과 `CHANGELOG.md`를 갱신하고 [지원 매트릭스](support-matrix.md)의 공개
지원 주장 및 `nimble.lock`을 검토한다. 아래 명령은 저장소 루트의 PowerShell에서
그대로 실행할 수 있다.

## 사전 검증

```text
nimble check
nimble test
nimble verify
nimble planStatus
git diff --check
```

| 명령 | 성공 기준 | 실패하면 다음 조치 |
| --- | --- | --- |
| `nimble check` | CLI가 컴파일된다. | 컴파일 오류를 수정하고 같은 명령부터 다시 실행한다. |
| `nimble test` | core 회귀 테스트가 모두 통과한다. | 실패한 테스트의 계약 또는 구현을 고치고 테스트를 다시 실행한다. |
| `nimble verify` | lockfile·문서·예제·public API gate가 모두 통과한다. | 출력된 하위 gate를 단독 실행해 원인을 고친 뒤 `nimble verify`를 다시 실행한다. |
| `nimble planStatus` | 체크리스트 수치를 릴리스 기록에 남긴다. | 미완료 또는 부분 완료 항목의 증거/제외 사유를 릴리스 기록에 남긴다. |
| `git diff --check` | 공백 오류가 없다. | 보고된 파일의 공백 오류를 고치고 다시 실행한다. |

`nimble verify` 안에는 `nimble lockCheck`, `nimble docsCheck`,
`nimble docsExamples`, `nimble publicApiCheck`가 포함된다. 따라서 개별 gate를
추가로 실행할 필요는 없지만, 실패 원인을 좁힐 때에는 해당 task를 단독으로 실행한다.

## artifact manifest

지원하는 각 target에서 release artifact를 만든 뒤, 실제 바이트의 SHA-256을 담은
deterministic manifest를 업로드 전에 생성한다. 다음은 PowerShell 예시이며 artifact
경로가 여러 개면 세미콜론(`;`)으로 연결한다.

```powershell
$env:MAHANAIM_RELEASE_MANIFEST = "release-artifacts.manifest"
$env:MAHANAIM_RELEASE_ARTIFACTS = "dist/mahanaim_cli.exe"
nimble releaseManifest
Get-Content $env:MAHANAIM_RELEASE_MANIFEST
```

`releaseManifest`가 `artifact environment is not configured`이라고 출력하면
**성공한 검증이 아니라 명시적 skip**이다. artifact를 만든 뒤 위 두 환경변수를
설정하고 다시 실행한다. command가 실패하면 누락된 artifact 경로, 중복 경로 또는
manifest 출력 위치를 고친 뒤 새 artifact로 다시 생성한다. manifest와 artifact를
같이 CI upload에 첨부한다.

CI matrix는 지원 target의 job과 artifact upload가 모두 성공했을 때만 release
evidence다. 로컬 결과는 필요한 macOS/Linux/provider live evidence를 대체하지
않는다. credential이 필요한 `postgresLive`, `redisLive`, `httpsLive`, `beastLive`는
환경이 없을 때 명시적으로 skip될 수 있으므로, 릴리스 기록에는 실행 결과 또는
credential skip 사유를 남긴다.

## 승인과 실패 처리

공개 API 변경에는 호환성/폐기 안내와 필요할 때 정확한 OpenAPI artifact를 붙인다.
배포 전에 이전 binary·configuration·migration rollback 입력을 보관한다. 어느 gate든
실패하면 qualification을 중단하고, 수정 또는 revert 후 **실패한 gate부터 전체
사전 검증 순서까지** 다시 실행한다. 롤백이 필요하면 traffic을 멈추고 readiness를
false로 전환한 뒤 drain, 이전 artifact/configuration 복원, 결과 기록 순서로 처리한다.
