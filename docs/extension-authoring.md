# 확장 작성

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** maintainers publishing a reusable Mahanaim integration.
**Verified with:** `nimble test`, consumer application tests.

Package an extension as a normal Nim package with a documented supported
Mahanaim version range, one explicit installer, and tests that use a fresh
`Application`. Register only through public APIs and fail clearly for duplicate
names, missing dependencies, or incompatible provider configuration.

Define ownership before writing code: the application owns process lifecycle,
credentials, network clients, and deployment policy; the extension owns only the
objects it constructs and must clean them up through the declared lifecycle hook.
Never register a route, provider, plugin, or adapter after startup begins.

Before release, test successful install, duplicate/dependency failure, startup/
shutdown cleanup, error redaction, resource disposal, and a consumer's minimal
route/service integration. Document any external service/live-test requirements.

로컬 plugin의 route/service 및 duplicate/dependency 실패 경로는
[`examples/plugin_extension.nim`](../examples/plugin_extension.nim)에서
`nimble docsExamples`로 실행한다. 외부 provider client의 credential, lifecycle,
live evidence는 extension 소비 애플리케이션이 별도 test/staging 환경에서 소유한다.
