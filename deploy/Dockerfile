# Application-owned deployment template.
#
# The framework does not guess an application's entry module. Set APP_MAIN to
# the generated application's Nim entrypoint when building this image.
FROM nimlang/nim:2.2.4 AS build

WORKDIR /workspace
COPY nimble.lock mahanaim.nimble ./
RUN nimble install -y
COPY . .

ARG APP_MAIN=src/app.nim
RUN nim c -d:release --opt:speed --out:/out/mahanaim_app "$APP_MAIN"

FROM debian:bookworm-slim AS runtime

# The runtime image has no compiler and runs as an unprivileged user. Runtime
# configuration belongs to the deployment environment, not to the image.
RUN groupadd --system mahanaim && \
    useradd --system --gid mahanaim --home-dir /nonexistent \
      --shell /usr/sbin/nologin mahanaim
COPY --from=build /out/mahanaim_app /usr/local/bin/mahanaim_app

ENV MAHANAIM_HOST=0.0.0.0 \
    MAHANAIM_PORT=8080
EXPOSE 8080

# SIGTERM gives the application lifecycle a chance to drain readiness,
# in-flight requests, database sessions, and durable job acknowledgements.
STOPSIGNAL SIGTERM
USER mahanaim
ENTRYPOINT ["/usr/local/bin/mahanaim_app"]
