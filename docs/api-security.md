# API 보안

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** maintainers exposing browser or machine API endpoints.
**Status:** authentication and provider integrations are experimental.
**Verified with:** `nimble test`

Choose one explicit authentication boundary per endpoint: signed browser session,
bearer/JWT verification, or an application-owned external introspection adapter.
Bind verified identity to `request.auth`; handlers should never parse raw cookies
or authorization headers. Apply role/group/object authorization as route
middleware, then re-check object ownership at the data boundary.

Use a strict CORS origin allowlist for browser APIs and make preflight behavior
match the real methods and headers. Rate-limit by a trusted identity or trusted
proxy-derived address, not an unverified forwarding header. CSRF is required for
cookie-authenticated unsafe browser requests; bearer-only APIs normally use an
authorization header instead of ambient cookies.

Set request body and deadline limits, redact secrets from problem details and
logs, and return generic 401/403/429 responses. Test an anonymous request,
wrong-role request, invalid CSRF request, rate-limit exhaustion, and rejected
CORS origin for every externally reachable API group.
