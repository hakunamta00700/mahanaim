# Execute a local TLS termination fixture around the real Mahanaim network
# adapter. The certificate is intentionally ephemeral and the client opts out
# of trust only for this self-signed local fixture; staging uses httpsLive with
# normal certificate verification.
$ErrorActionPreference = 'Stop'
$containerName = 'mahanaim-https-wire'
$upstreamContainer = 'mahanaim-https-upstream'
$networkName = 'mahanaim-https-net'
$certDirectory = Join-Path $env:TEMP ('mahanaim-https-' + [Guid]::NewGuid().ToString('N'))
$wirePassed = $false

try {
  New-Item -ItemType Directory -Path $certDirectory | Out-Null
  foreach ($name in @($containerName, $upstreamContainer)) {
    $existingContainer = docker ps -a --filter "name=^/$name$" --format '{{.Names}}'
    if ($existingContainer -eq $name) {
      docker rm -f $name | Out-Null
    }
  }
  $existingNetwork = docker network ls --filter "name=^$networkName$" --format '{{.Name}}'
  if ($existingNetwork -eq $networkName) {
    docker network rm $networkName | Out-Null
  }
  docker network create $networkName | Out-Null
  $networkInfo = docker network inspect $networkName | ConvertFrom-Json
  $subnet = $networkInfo[0].IPAM.Config[0].Subnet
  $octets = $subnet.Split('/')[0].Split('.')
  if ($octets.Count -ne 4) { throw 'HTTPS fixture received an invalid Docker subnet' }
  # Static addresses make the upstream's exact trusted proxy peer explicit;
  # no CIDR-wide trust is needed for this fixture.
  $upstreamIp = "$($octets[0]).$($octets[1]).$($octets[2]).2"
  $proxyIp = "$($octets[0]).$($octets[1]).$($octets[2]).3"

  # Generate a certificate whose SAN matches the Host header sent by the
  # client. No certificate material is kept after this fixture exits.
  docker run --rm -v "${certDirectory}:/certs" alpine:3.20 sh -c `
    "apk add --no-cache openssl >/dev/null && openssl req -x509 -nodes -newkey rsa:2048 -days 1 -keyout /certs/server.key -out /certs/server.crt -subj '/CN=public.example' -addext 'subjectAltName=DNS:public.example' >/dev/null 2>&1"
  if ($LASTEXITCODE -ne 0) { throw 'TLS certificate generation failed' }

  docker run -d --name $upstreamContainer --network $networkName `
    -v "${PWD}:/workspace" -w /workspace `
    -e MAHANAIM_HTTPS_UPSTREAM_PORT=18080 `
    -e MAHANAIM_HTTPS_TRUSTED_PROXY=$proxyIp `
    -e MAHANAIM_HTTPS_PUBLIC_HOST=public.example `
    --ip $upstreamIp `
    nimlang/nim:2.2.4 sh -c "apt-get update -qq && apt-get install -y -qq libpq5 >/dev/null && nimble install -y && nimble httpsLiveUpstream && ./tests/test_https_upstream"
  if ($LASTEXITCODE -ne 0) { throw 'HTTPS upstream container failed to start' }
  $ready = $false
  for ($attempt = 0; $attempt -lt 120; $attempt++) {
    $running = docker inspect -f '{{.State.Running}}' $upstreamContainer 2>$null
    $logs = docker logs $upstreamContainer
    if ($running -eq 'true' -and $logs -match 'HTTPS upstream ready') {
      $ready = $true
      break
    }
    Start-Sleep -Milliseconds 500
  }
  if (-not $ready) {
    docker logs $upstreamContainer
    throw 'HTTPS upstream did not become ready'
  }

  docker run -d --name $containerName --network $networkName --ip $proxyIp `
    -p 18443:18443 `
    -v "${PWD}\tests\nginx-https-wire.conf:/etc/nginx/nginx.conf:ro" `
    -v "${certDirectory}:/etc/nginx/certs:ro" nginx:1.27-alpine | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'HTTPS proxy container failed to start' }
  Start-Sleep -Seconds 2

  $env:MAHANAIM_HTTPS_URL = 'https://127.0.0.1:18443/wire'
  $env:MAHANAIM_HTTPS_HOST_HEADER = 'public.example'
  $env:MAHANAIM_HTTPS_INSECURE = '1'
  nimble httpsLive
  if ($LASTEXITCODE -ne 0) { throw 'HTTPS wire contract failed' }
  $wirePassed = $true
}
finally {
  foreach ($name in @($containerName, $upstreamContainer)) {
    $existingContainer = docker ps -a --filter "name=^/$name$" --format '{{.Names}}'
    if ($existingContainer -eq $name) {
      if (-not $wirePassed) {
        docker logs $name
      }
      docker rm -f $name | Out-Null
    }
  }
  $existingNetwork = docker network ls --filter "name=^$networkName$" --format '{{.Name}}'
  if ($existingNetwork -eq $networkName) {
    docker network rm $networkName | Out-Null
  }
  if (Test-Path -LiteralPath $certDirectory) {
    Remove-Item -LiteralPath $certDirectory -Recurse -Force
  }
}
