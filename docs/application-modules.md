# Application modules

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** application authors structuring their own codebase.
**Verified with:** `nimble test`

`ApplicationModule` is an application composition unit, not a dynamically loaded
plugin. Modules declare imports, providers, controllers, routes, startup/shutdown
hooks, and exports, then the root installs them with `installModules` before
startup. Installation validates the graph and keeps service/provider ownership
explicit.

Use modules for first-party application features that share a release and source
tree. Use a plugin when packaging an optional reusable integration with manifest
metadata. Neither is auto-discovered from files or imports; the composition root
chooses what is installed and in which dependency graph.

Exports describe intended inter-module service visibility, not a global locator.
Dispose request/task scopes at their owner boundary and do not let a module close
an adapter owned by the application or another module.
