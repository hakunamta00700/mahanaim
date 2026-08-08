# Security configuration

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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

## 거부 경로 재현

다음 경로는 application test에서 반드시 재현한다. framework repository에서는
`nimble test`가 같은 상태·응답 코드를 contract로 검증한다.

| 상황 | 기대 응답 | 확인할 계약 |
| --- | --- | --- |
| 익명 또는 역할 없는 보호 route 요청 | `403` | `authorization policy composes roles groups object checks and route guards` |
| CSRF token 누락·위조 POST | `403` | `security policy issues and validates signed CSRF tokens` |
| fixed-window 제한을 초과한 요청 | `429` | `security policy applies an application-wide fixed-window rate limit` |

인증이 통과한 요청이라도 route guard와 object policy는 별도로 적용한다. 실제
application test에서는 anonymous, wrong-role, wrong-object, missing/forged CSRF,
limit 초과를 모두 만들고 error body·audit log에 credential이 없는지 확인한다.
