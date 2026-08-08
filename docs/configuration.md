# Mahanaim 설정

**마지막 검증:** `nimble docsCheck`

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** 개발·테스트·배포 환경을 구성하는 개발자와 운영자
**안정성 기준:** config provider와 secret redaction은 stable 계약이다.
**검증:** `nimble test`, `mahanaim check`

Mahanaim은 configuration provider를 통해 `.env`, JSON, TOML, 환경변수를 읽고
typed `AppConfig`로 검증한다. provider 우선순위와 프로젝트별 설정 구성은
composition root가 명시적으로 소유한다.

## 개발 환경 예시

생성 프로젝트의 `.env.example`을 복사해 로컬 `.env`를 만든다.

```text
MAHANAIM_ENV=development
MAHANAIM_HOST=127.0.0.1
MAHANAIM_PORT=8000
```

`.env`에는 secret을 둘 수 있지만 git에 추가하지 않는다. 저장소에는
`.env.example`처럼 값이 없는 예시만 둔다.

## 환경변수

일반 scalar 설정은 `MAHANAIM_<KEY>` 형식으로 지정한다. 구조화된 값은
`MAHANAIM_VALUE_<KEY>=<JSON>`으로 전달할 수 있다. malformed JSON이나 범위를
벗어난 포트처럼 유효하지 않은 값은 시작 전 검사에서 오류가 된다.

```text
MAHANAIM_PORT=8000
MAHANAIM_EXECUTOR_MAX_QUEUED_JOBS=32
MAHANAIM_VALUE_FEATURE_FLAGS={"catalog":true}
```

정확한 `AppConfig` field와 provider 우선순위는 public config API를 기준으로 하며,
배포 환경에서는 `mahanaim check`로 실제 적용 값을 검사한다.

## 비밀값

- DB DSN/password, signing secret, SMTP credential, OAuth secret은 source와 CLI
  argument에 넣지 않는다.
- `admin create-user`는 password를 `MAHANAIM_ADMIN_PASSWORD`에서만 읽는다.
- structured log는 configured secret을 redaction하지만, application이 직접
  출력하는 값까지 자동으로 보호하지는 않는다.

## 검사와 문제 해결

```text
mahanaim check
mahanaim dev
```

`check`은 config, route, model, migration, security, execution 오류를 한 report로
보여 준다. `dev`는 같은 검사를 통과했을 때만 개발 설정을 출력한다.

| 증상 | 원인과 조치 |
| --- | --- |
| 포트 오류 | `MAHANAIM_PORT`가 1~65535인지 확인한다. |
| 구조화 설정 오류 | `MAHANAIM_VALUE_` 뒤 값이 유효한 JSON인지 확인한다. |
| secret이 log에 보임 | application log/event에 secret을 직접 넣지 말고 redaction 대상 설정을 사용한다. |
| production에서 HTTPS 오류 | [보안 배포 점검표](security-deployment-checklist.md)의 allowed host/trusted proxy 설정을 확인한다. |
