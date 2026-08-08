# Core 애플리케이션 API

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](../support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](../support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](../index.md) · [지원 매트릭스](../support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](../support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**소스:** `src/mahanaim/core.nim`, `application.nim`, `router.nim`.
**검증:** `nimble publicApiCheck`, `nimble docsExamples`, `nimble test`.

## `newApplication`

config, security, execution policy로 독립된 `Application`을 만듭니다. 호출자가
route/module/plugin 등록을 소유하며 `startup` 전에 마쳐야 합니다. 시작 뒤의
등록은 `ValueError`를 발생시킵니다.

```nim
let app = newApplication()
app.get("/health", "health", healthHandler)
```

## `get`, `post`, `addRoute`, and `websocket`

비동기 HTTP handler 또는 WebSocket session handler를 등록합니다. route 이름은
유일해야 하고 `addRoute`는 GET/POST 외 method도 받습니다. path 문법, middleware
순서, 오류 처리, URL 생성은 [라우팅](../routing.md)을 보세요. 중복 이름 또는
시작 뒤 등록은 `ValueError`를 발생시킵니다.

## `Request` and `Response`

`Request`는 path/query/header/cookie/body 데이터와 `pathParams`를 담는
adapter-neutral 입력 snapshot입니다. `Response`는 status, headers, body,
representation, 선택된 협상 variant를 가집니다. 안전하지 않은 content metadata를
직접 만들지 말고 `textResponse`, `htmlResponse`, `jsonResponse`, `fileResponse`,
`streamResponse`, `sseResponse`를 사용하세요. [응답과 협상](../responses-and-negotiation.md)을
참조하세요.

## `FieldSpec` and `validate`

`stringField`, `integerField`, `floatField`, `booleanField`, `jsonField`로 입력
field를 선언한 뒤 `request.validate`를 호출합니다. 모든 검증 issue를 반환하고
`validationResponse`는 표준 problem response를 렌더링합니다. 자세한 내용은
[요청과 검증](../requests-and-validation.md)을 보세요.
