## Small Mahanaim upstream used by the HTTPS reverse-proxy wire fixture.
##
## Keeping the upstream as a real NetworkServer is important: an in-process
## dispatch test cannot prove that the proxy's TCP peer, forwarded headers,
## and application security middleware agree at the network boundary.

import std/[asyncdispatch, options, os, strutils]
import mahanaim/[application, config, core, http_adapter, security]

proc wireProbe(request: Request): Future[Response] {.async, gcsafe.} =
  ## Expose only the normalized transport values needed by the external test.
  ## A production handler would return application data instead; the probe
  ## deliberately makes a forged forwarded header observable in test output.
  let host = request.header("host").get("")
  result = textResponse(request.scheme & "|" & host)
  result.setCookie("wire_probe", "ok", httpOnly = true, secure = true,
    sameSite = "Lax")

proc runUpstream() =
  let portText = getEnv("MAHANAIM_HTTPS_UPSTREAM_PORT", "18080")
  let trustedProxy = getEnv("MAHANAIM_HTTPS_TRUSTED_PROXY", "127.0.0.1")
  let publicHost = getEnv("MAHANAIM_HTTPS_PUBLIC_HOST", "public.example")
  let port = parseInt(portText)

  var policy = defaultSecurityPolicy()
  policy.requireHttps = true
  policy.trustedProxies = @[trustedProxy]
  policy.allowedHosts = @[publicHost]
  let app = newApplication(defaultConfig(), policy)
  app.get("/wire", "https-wire-probe", wireProbe)

  let server = newNetworkServer(app, "0.0.0.0", port)
  let serving = server.serve()
  var ready = false
  for attempt in 0 ..< 100:
    try:
      if server.boundPort().uint16 > 0:
        ready = true
        break
    except OSError:
      discard
    if attempt + 1 < 100:
      poll(10)
  if not ready:
    raise newException(IOError, "HTTPS upstream did not bind its port")
  echo "HTTPS upstream ready"
  waitFor serving

when isMainModule:
  runUpstream()
