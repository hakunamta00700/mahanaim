# Deployment

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** operators deploying an application behind Docker/nginx or systemd.
**Verified with:** `nimble verify`; production TLS requires live evidence.

Use [deployment recipes](deployment-recipes.md) as the canonical Docker, nginx,
and systemd reference. Set `MAHANAIM_APP_MAIN` to the application entry module,
build the image, start it, and wait for readiness before sending traffic. Nginx
owns TLS termination, HTTP-to-HTTPS redirects, and WebSocket upgrades; trust
forwarded headers only from the direct configured proxy.

Deploy in this order: validate lockfile/tests, build artifact, run a safe schema
migration, start a new instance, wait for readiness, shift traffic, then drain
the old instance. Draining sets readiness false, closes acceptance, finishes a
bounded request/database/job budget, and runs shutdown hooks. Rollback traffic
only after confirming migration compatibility and backup procedure.

For systemd, keep service environment files outside the repository, then use
`systemctl daemon-reload`, `enable --now`, and `is-active`. Align `TimeoutStopSec`
with the drain budget. Follow the [security checklist](security-deployment-checklist.md).
