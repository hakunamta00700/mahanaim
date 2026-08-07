# Application과 모듈 구성

**대상 독자:** 여러 기능을 하나의 Mahanaim 애플리케이션으로 조합하는 개발자
**안정성 기준:** Application routing과 dependency injection은 stable 범위다.
**검증:** `nimble test`, `nimble publicApiCheck`

## Application의 책임

`Application`은 router, middleware, security policy, lifecycle hook, DI service
container, observability, application-owned adapter를 소유한다. 하나의 process
전역 singleton이 아니므로 테스트마다 새 Application을 만들 수 있다.

```nim
import std/asyncdispatch
import mahanaim

let app = newApplication()
app.get("/health", "health",
  proc(request: Request): Future[Response] {.async, gcsafe.} =
    discard request
    return textResponse("ok"))
```

최소 실행 가능한 예제는 [examples/minimal_app.nim](../examples/minimal_app.nim)이며
`nimble docsExamples`로 컴파일·실행된다.

## ApplicationModule

`ApplicationModule`은 관련 provider, controller, route, lifecycle hook을 함께
정의한다. module은 자동 발견하지 않으며 composition root에서 설치한다.

```nim
let inventory = newApplicationModule("inventory")
inventory.addModuleRoute(proc(app: Application) {.gcsafe.} =
  app.get("/inventory/health", "inventory-health",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      discard request
      return textResponse("ok")))

let app = newApplication()
app.installModules([inventory])
```

module은 import 관계와 export를 명시하므로 duplicate provider, cycle, 의도하지 않은
override를 설치 전에 검사할 수 있다.

## Lifecycle

`onStartup`과 `onShutdown` hook은 `startup()` 전까지만 등록할 수 있다. startup은
extension registration을 닫고, shutdown은 adapter/provider를 정리한다.

```nim
app.onStartup(proc() {.gcsafe.} = echo "ready")
app.onShutdown(proc() {.gcsafe.} = echo "stopped")
app.startup()
try:
  # dispatch 또는 server 실행
  discard
finally:
  app.shutdown()
```

## DI와 scope

provider는 application, request, task scope를 명시한다. request scope는 dispatch마다
생성·정리되고 task scope는 호출자가 소유한다. provider 그래프와 disposal은
Application이 검증하며, 동적 global registry를 사용하지 않는다.

## Plugin과의 구분

module은 보통 한 프로젝트 안의 구성 단위다. plugin은 manifest, phase, dependency
graph를 가진 재사용 확장이다. plugin/확장 작성 가이드는 문서화 계획에 따라 추가한다.

## 실패와 제한

- startup 뒤에는 route/provider/plugin/command 등록이 실패한다.
- handler가 blocking 작업을 한다면 execution policy와 executor 경계를 따라야 한다.
- 외부 DB·Redis·SMTP의 connection lifecycle은 Application이 아니라 프로젝트가
  선택한 adapter/provider에서 명시적으로 구성한다.
