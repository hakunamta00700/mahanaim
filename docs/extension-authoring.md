# Extension authoring

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
