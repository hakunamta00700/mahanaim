# Mahanaim CLI 레퍼런스

**대상 독자:** 프로젝트를 생성·검사·운영하는 개발자와 운영자
**안정성 기준:** 명령의 구현 범위는 [지원 매트릭스](support-matrix.md)를 따른다.
**검증:** `nimble check`, `nimble test`

`mahanaim` CLI는 project generator와 application-owned command frontend를 제공한다.
DB, admin, durable job처럼 application wiring이 필요한 명령은 생성 프로젝트의
entry point 또는 embedding Application에서 실행해야 한다.

## 명령 요약

| 명령 | 용도 | 주요 실패 조건 |
| --- | --- | --- |
| `new NAME [PATH]` | 빈 프로젝트 생성 | 유효하지 않은 Nim identifier, 비어 있지 않은 대상 |
| `app NAME [PROJECT_ROOT]` | 기존 프로젝트에 ApplicationModule 생성 | `src`/`tests`가 없거나 대상 파일이 이미 존재 |
| `check` | config·route·model·security 검사 | validation error가 있으면 종료 코드 1 |
| `dev` | 설정을 로드하고 같은 pre-flight 검사 실행 | `check`와 같은 오류 |
| `test` | `nimble test` 실행 | 테스트 실패의 종료 코드 전달 |
| `db status|migrate|up|rollback [PATH]` | migration 상태/실행/되돌리기 | migration registry/provider 미구성 |
| `db seed [PATH]` | application-owned seed 실행 | seed registry 미구성 |
| `openapi [PATH]` | 등록 route의 OpenAPI JSON 출력/파일 생성 | output path가 비어 있거나 인자가 둘 이상 |
| `openapi-ts [PATH]` | TypeScript client 출력/파일 생성 | output path가 비어 있거나 인자가 둘 이상 |
| `admin create-user <identifier> [subject]` | administrator 계정 생성 | creator 미구성, `MAHANAIM_ADMIN_PASSWORD` 누락 |
| `static collect <source...> --output <path>` | 안전한 정적 파일 수집 | source/output 누락, unsafe path, 충돌 |
| `jobs run [max]` | pending durable job 실행 | durable store/registry 미구성, `max < 1` |
| `jobs recover` | processing 상태 job 복구 | durable store/registry 미구성 |

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
