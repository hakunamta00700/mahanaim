# Observability

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** operators integrating health checks, logs, traces, and metrics.
**Verified with:** `nimble test`

The observability middleware assigns or preserves `X-Request-ID`, tracks request,
error, and in-flight counters, and propagates W3C trace context. Record these as
correlation keys, not user identity. Configure redaction before startup and never
add password, token, cookie, authorization, or full payload fields to logs.

Expose application-owned routes for `healthResponse`, `readinessResponse`, and
`metricsResponse`. Health answers process reachability; readiness controls traffic
admission and must become false before draining. Prometheus text metrics contain
aggregate counters/gauges, not request IDs, trace IDs, secrets, cache keys, or
payloads. Attach vendor exporters through the existing sinks.

## 로컬 확인 절차

composition root에서 `/health`, `/ready`, `/metrics`처럼 프로젝트가 선택한 route에
각 response를 연결한다. 아래 경로는 예시이며, public deployment에서는 proxy와
network policy에 맞춰 노출 범위를 제한한다.

```text
curl --fail http://127.0.0.1:8000/health
curl --fail http://127.0.0.1:8000/ready
curl --fail http://127.0.0.1:8000/metrics
```

첫 명령은 process reachability, 두 번째는 traffic admission, 세 번째는 Prometheus
text 형식의 aggregate metric을 확인한다. shutdown/drain 연습에서는 `/ready`가
먼저 실패하는지 확인하고, request ID나 secret이 `/metrics` 또는 log에 나타나지
않는지 검사한다. Docker와 systemd 실행 절차는 [배포 레시피](deployment-recipes.md)를
따른다.
