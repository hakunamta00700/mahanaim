# API security

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
