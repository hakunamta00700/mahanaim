# Authentication

**Audience:** applications selecting an identity transport.
**Status:** experimental; verify provider behavior in deployment.
**Verified with:** `nimble test`

Authentication backends are explicit: signed session cookies,
`newBearerTokenAuthBackend`, `newJwtTokenAuthBackend`, and
`newIntrospectionAuthBackend`. Configure one or more trusted backends in the
security policy before startup; successful authentication appears as
`request.auth`. Handlers consume that context and never parse cookie or token
syntax directly.

Use signed sessions for browser login/logout flows and secure, HttpOnly cookies
over HTTPS. Use bearer/JWT for non-browser clients with issuer, audience, key
rotation, expiry, and revocation decisions documented by the application. An
introspection callback must have bounded timeout/retry behavior and must not log
the supplied token.

Account storage, registration, password reset, and password change are
application-owned boundaries. Store reset credentials as short-lived, single-use
records or signed tokens, disclose no account existence in recovery responses,
and invalidate relevant sessions after a credential change.
