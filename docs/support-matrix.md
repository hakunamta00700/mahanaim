# 지원 런타임과 artifact 무결성

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
