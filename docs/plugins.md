# Plugins

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** applications grouping optional framework integrations.
**Verified with:** `nimble test`

`PluginDefinition` pairs a `PluginManifest` with an explicit installer. The
manifest contains name, version, registration phase, and dependencies. Call
`app.use(plugin)` during application composition; dependency graph and duplicate
validation run before installation, and registration after startup is rejected.

An installer can register routes, middleware, services, serialization codecs,
storage, authentication backends, commands, or Admin extensions through the
same application APIs used by the root. It must not mutate global registries or
assume it owns an adapter supplied by another plugin/application.

There is no built-in plugin scaffold, filesystem registry/search/installation,
hot reload, dynamic loading, or semantic-version dependency solver. Distribute
plugins as ordinary Nim packages with explicit imports and composition calls.

## 실행 예제

[`examples/plugin_extension.nim`](../examples/plugin_extension.nim)은 하나의
plugin이 application-scope service와 `/plugin-greeting` route를 설치하는 과정을
보인다. 같은 manifest의 중복 설치와 존재하지 않는 dependency는 `ValueError`로
거부됨을 확인한다. `nimble docsExamples`로 실행하면 `plugin-extension-ok`를
출력한다.
