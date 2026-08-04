## Optional HTTPS reverse-proxy wire contract.
##
## The test intentionally accepts a complete URL so CI/staging can provide a
## real ingress endpoint with a certificate trusted by the runner. Local
## self-signed fixtures may set MAHANAIM_HTTPS_INSECURE=1 explicitly; that
## switch is never the default for a release/staging verification.

import std/[httpclient, httpcore, net, os, strutils]

proc runLiveContract() =
  let url = getEnv("MAHANAIM_HTTPS_URL")
  if url.len == 0:
    echo "HTTPS live test skipped: MAHANAIM_HTTPS_URL is not configured"
    quit(0)

  let expectedBody = getEnv("MAHANAIM_HTTPS_EXPECTED_BODY", "https|public.example")
  let expectedCookie = getEnv("MAHANAIM_HTTPS_EXPECTED_COOKIE", "wire_probe=ok")
  let insecure = getEnv("MAHANAIM_HTTPS_INSECURE") == "1"
  let context = newContext(verifyMode = if insecure: CVerifyNone else: CVerifyPeer)
  let client = newHttpClient(sslContext = context)
  client.headers = newHttpHeaders({"Host": getEnv(
    "MAHANAIM_HTTPS_HOST_HEADER", "public.example")})
  defer: client.close()

  let response = client.get(url)
  let cookie = response.headers.getOrDefault("set-cookie")
  let cookieLower = cookie.toLowerAscii()
  let expectedCookieLower = expectedCookie.toLowerAscii()
  let statusOk = response.code == Http200
  let bodyOk = response.body == expectedBody
  let cookieOk = cookieLower.contains(expectedCookieLower) and
    cookieLower.contains("secure") and cookieLower.contains("httponly")
  if not statusOk or not bodyOk or not cookieOk:
    raise newException(ValueError,
      "HTTPS wire contract mismatch: statusOk=" & $statusOk &
      ", bodyOk=" & $bodyOk & ", cookieOk=" & $cookieOk &
      ", status=" & $response.code & ", body=" & response.body &
      ", cookie=" & cookie)
  echo "HTTPS reverse-proxy live contract passed"

when isMainModule:
  runLiveContract()
