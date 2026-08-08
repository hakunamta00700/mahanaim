# Mahanaim deployment recipes

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

These files are deployment templates, not an application generator. The
application owns its entry module, credentials, migration policy, TLS renewal,
and route-level readiness behavior.

This guide is the canonical source for Docker/nginx/systemd commands and files.
For runtime health, drain, and provider recovery policy read the
[operations guide](operations-guide.md); for release gates and rollback
decisions read the [adoption and release guide](adoption-and-release.md).

## Docker and reverse proxy

Set `MAHANAIM_APP_MAIN` to the generated application entrypoint and review the
runtime command before building:

```text
MAHANAIM_APP_MAIN=src/app.nim docker compose -f deploy/docker-compose.yml build
docker compose -f deploy/docker-compose.yml up -d
docker compose -f deploy/docker-compose.yml ps
```

The multi-stage image keeps the compiler out of the runtime image and runs as
`mahanaim`. Nginx terminates TLS, redirects HTTP to HTTPS, forwards trusted
scheme/host headers, and preserves WebSocket upgrades. Certificates are
deployment secrets; they are never copied into the image.

The compose healthcheck must represent application readiness, not merely an
open TCP port. `stop_grace_period` and SIGTERM allow the application to mark
itself unready and drain requests, database sessions, and durable job
acknowledgements before the container exits.

## systemd

Install `deploy/mahanaim.service` with an application-owned binary at
`/opt/mahanaim/bin/mahanaim_app` and an optional environment file at
`/etc/mahanaim/mahanaim.env`:

```text
sudo systemctl daemon-reload
sudo systemctl enable --now mahanaim.service
systemctl is-active mahanaim.service
```

`KillSignal=SIGTERM` and `TimeoutStopSec` must match the application's drain
budget. This is the framework's graceful shutdown boundary: operators should
verify readiness becomes false before replacing a worker and record the
process exit and rollback evidence in the deployment runbook.
