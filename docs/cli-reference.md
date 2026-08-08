# Mahanaim CLI 레퍼런스

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**마지막 검증:** `nimble docsCheck`

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** 프로젝트를 생성·검사·운영하는 개발자와 운영자
**안정성 기준:** 명령의 구현 범위는 [지원 매트릭스](support-matrix.md)를 따른다.
**검증:** `nimble docsCheck` (실제 `--help`와 실패 종료 코드 포함)

`mahanaim` CLI는 project generator와 application-owned command frontend를 제공한다.
DB, admin, durable job처럼 application wiring이 필요한 명령은 생성 프로젝트의
entry point 또는 embedding Application에서 실행해야 한다.

## 명령 요약

문서에서는 설치된 CLI를 `mahanaim`으로 표기한다. 소스 저장소에서 직접 빌드한
Windows binary 이름은 `mahanaim_cli.exe`이며, Unix에서는 `mahanaim_cli`다.
성공은 종료 코드 `0`, 잘못된 인자·설정·미구성 application-owned provider는 `1`을
반환한다. `test`는 내부 `nimble test`의 종료 코드를 그대로 반환한다.

| 명령 | 용도 | 주요 실패 조건 | 종료 코드 |
| --- | --- | --- | --- |
| `new NAME [PATH]` | 빈 프로젝트 생성 | 유효하지 않은 Nim identifier, 비어 있지 않은 대상 | 성공 `0`, 사용 오류 `1` |
| `app NAME [PROJECT_ROOT]` | 기존 프로젝트에 ApplicationModule 생성 | `src`/`tests`가 없거나 대상 파일이 이미 존재 | 성공 `0`, 사용 오류 `1` |
| `check` | config·route·model·security 검사 | validation error | 성공 `0`, 검사 실패 `1` |
| `dev` | 설정을 로드하고 같은 pre-flight 검사 실행 | `check`와 같은 오류 | 성공 `0`, 검사 실패 `1` |
| `test` | `nimble test` 실행 | 테스트 실패 | 하위 테스트 종료 코드 전달 |
| `db status|migrate|up|rollback [PATH]` | migration 상태/실행/되돌리기 | migration registry/provider 미구성 | 성공 `0`, 오류 `1` |
| `db seed [PATH]` | application-owned seed 실행 | seed registry 미구성 | 성공 `0`, 오류 `1` |
| `openapi [PATH]` | 등록 route의 OpenAPI JSON 출력/파일 생성 | output path가 비어 있거나 인자가 둘 이상 | 성공 `0`, 오류 `1` |
| `openapi-ts [PATH]` | TypeScript client 출력/파일 생성 | output path가 비어 있거나 인자가 둘 이상 | 성공 `0`, 오류 `1` |
| `admin create-user <identifier> [subject]` | administrator 계정 생성 | creator 미구성, `MAHANAIM_ADMIN_PASSWORD` 누락 | 성공 `0`, 오류 `1` |
| `static collect <source...> --output <path>` | 안전한 정적 파일 수집 | source/output 누락, unsafe path, 충돌 | 성공 `0`, 오류 `1` |
| `jobs run [max]` | pending durable job 실행 | durable store/registry 미구성, `max < 1` | 성공 `0`, 오류 `1` |
| `jobs recover` | processing 상태 job 복구 | durable store/registry 미구성 | 성공 `0`, 오류 `1` |

## 일반 사용 예시

```text
mahanaim new shop ./shop
cd shop
mahanaim check
mahanaim db status
mahanaim db up
mahanaim openapi openapi.json
mahanaim openapi-ts client.ts
```

생성 앱을 직접 실행할 때는 프로젝트 binary에 명령을 전달한다. framework CLI가
빈 Application을 만들면 migration, admin creator, durable job handler 같은
프로젝트 소유 설정을 알 수 없기 때문이다.

## 보안 주의

`admin create-user`의 비밀번호는 command line에 전달하지 않는다.

```text
MAHANAIM_ADMIN_PASSWORD=<안전한-비밀값> <프로젝트-binary> admin create-user admin@example.test
```

PowerShell에서는 environment variable을 현재 process에만 설정하고, shell history나
CI log에 값이 출력되지 않도록 secret store를 사용한다.

## 더 알아보기

- migration, static assets, jobs, Admin 운영 가이드는 문서화 계획에 따라 추가한다.
