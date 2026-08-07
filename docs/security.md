# Security configuration

**Audience:** application owners changing public-network defaults.
**Verified with:** `nimble test`; deployment evidence remains environment-specific.

`SecurityPolicy` centralizes CSRF, CORS, CSP/security headers, allowed hosts,
cookie settings, trusted proxies, HTTPS, and rate limits. Keep secrets in
environment variables or a secret store; the application observability boundary
redacts configured values, but developers must also avoid writing raw tokens,
cookies, bodies, and authorization headers to logs or problem responses.

Enable secure cookies and `requireHttps` for public deployment. Trust forwarded
scheme/host/client information only when `Request.remoteAddress` is a direct,
allowlisted proxy. Set `allowedHosts` and CORS origins to exact public values;
do not combine wildcard origins with credentials. Bound request body size,
request timeout, rate limit window, and rate-limit keys for the actual workload.

Configuration checks are automated, while TLS certificate, proxy forwarding,
DNS, and real browser headers require staging evidence. Follow the
[security deployment checklist](security-deployment-checklist.md) before every
public release; it explicitly separates local checks from manual/live proof.
