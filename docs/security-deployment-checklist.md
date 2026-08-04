# 보안 배포 점검표

이 문서는 Mahanaim 애플리케이션을 공개 네트워크에 배포하기 전에 확인할
보안 기본값과 운영 경계를 기록한다. 애플리케이션 설정은 프레임워크가
검사할 수 있지만, TLS 종료와 프록시 설정은 배포 환경에서 별도로 검증해야
한다.

## 애플리케이션 설정

- [ ] `SecurityPolicy.secureCookie`가 `true`인지 확인한다.
- [ ] 세션·서명·CSRF secret을 환경 변수 또는 secret store에서 주입한다.
- [ ] secret을 소스, 설정 파일, 로그, 오류 응답에 저장하지 않는다.
- [ ] `SecurityPolicy.allowedHosts`에 실제 public host만 등록한다.
- [ ] 필요할 때만 CORS origin을 허용하고 wildcard와 credential 조합을 피한다.
- [ ] `SecurityPolicy.rateLimitRequests`와 `rateLimitWindowSeconds`를 사용자·IP·토큰 정책에 맞게 설정한다.
- [ ] rate limit을 여러 인스턴스에서 사용할 경우 shared counter adapter의 TTL·clock·eviction 정책을 확인한다.
- [ ] `AppConfig.requestTimeoutMs`와 request body size limit을 업무 특성에 맞게 제한한다.
- [ ] upload 저장소가 web root 밖에 있고 filename/path traversal 검증을 통과하는지 확인한다.

## TLS와 reverse proxy

- [ ] 외부 HTTP 요청을 HTTPS로 redirect하고, 애플리케이션은 신뢰할 수 있는 proxy header만 사용한다.
- [ ] TLS 인증서 만료·갱신 자동화를 확인한다.
- [ ] TLS 1.2 이상과 안전한 cipher policy를 사용한다.
- [ ] reverse proxy의 request body, header, idle timeout이 애플리케이션 제한보다 느슨하지 않은지 확인한다.
- [ ] WebSocket과 SSE upgrade/streaming이 HTTPS 연결에서 유지되는지 smoke test한다.
- [ ] proxy가 원본 host와 scheme을 위조할 수 없도록 trusted proxy 범위를 제한한다.

## 배포 후 검증

- [ ] `nimble check`, `nimble test`, `nimble verify`를 배포 artifact와 같은 dependency lock으로 실행한다.
- [ ] health/readiness endpoint가 secret이나 내부 경로를 노출하지 않는지 확인한다.
- [ ] 보안 헤더, `Set-Cookie`의 `Secure`·`HttpOnly`·`SameSite`, CORS 응답을 실제 HTTPS endpoint에서 확인한다.
- [ ] rate limit 초과, request timeout, oversized body, invalid host가 예상된 4xx/5xx와 로그 구조로 나타나는지 확인한다.
- [ ] 로그와 tracing에 password, token, cookie, authorization header가 남지 않는지 확인한다.

## 자동화 범위

현재 `check`는 설정·route·model·migration·security·execution의 정적 계약을
검사한다. TLS 인증서, reverse proxy, 외부 DNS와 실제 HTTPS wire 동작은 배포
환경 의존성이므로 이 점검표와 live smoke test에서 검증한다.
