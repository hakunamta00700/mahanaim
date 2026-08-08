# Mahanaim Definition of Done

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

기능 하나를 완료로 표시하려면 구현 코드만 추가하는 것으로 충분하지 않다.
아래 체크리스트를 기능의 책임자와 리뷰어가 함께 확인하고, 증거가 없는 항목은
완료로 표시하지 않는다.

## 기능 단위 체크리스트

- [ ] 요구사항 ID와 우선순위가 `plan.md`에 연결되어 있다.
- [ ] framework-neutral 계약과 adapter 경계가 정의되어 있다.
- [ ] 정상 경로와 잘못된 입력/권한/실패 경로가 구현되어 있다.
- [ ] 외부 시스템 장애 시 timeout, retry, fail-closed 또는 명시적 fallback 정책이 있다.
- [ ] 단위 테스트가 순수 정책과 경계 조건을 검증한다.
- [ ] 통합 또는 wire 테스트가 해당 adapter의 실제 경계를 검증한다.
- [ ] 테스트가 공유 상태, 순서, 네트워크 timing에 불필요하게 의존하지 않는다.
- [ ] 공개 API와 설정 기본값의 보안 영향을 검토했다.
- [ ] 코드에 책임 분리와 외부 의존성 소유권을 설명하는 주석이 있다.
- [ ] 사용자 문서, 운영 절차, migration/호환성 주의사항을 갱신했다.
- [ ] `plan.md`와 상세 implementation plan의 상태가 실제 범위와 일치한다.
- [ ] first-party 기능의 성숙도·지원 대상·live evidence가 `support-matrix.md`에 기록되어 있다.

## 검증 게이트

로컬 또는 CI에서 다음 명령을 모두 통과해야 한다.

```text
nimble test
nimble check
nimble verify
nimble docsCheck
git diff --check
```

backend·OS·Nim 버전·외부 서비스가 요구되는 기능은 해당 환경의 별도 gate도
통과해야 한다.

- [x] PostgreSQL live contract를 실행하거나, credential 부재에 대한 명시적인 skip 증거를 남겼다.
- [x] Redis/Valkey compatibility와 eviction 검증 gate를 실행했다.
- [x] Linux Beast/httpx live socket 및 shutdown wire fixture와 gate를 실행해 handshake, WebSocket frame, ownership handoff, graceful close를 검증했다.
- [x] Docker nginx와 Nim 2.2.4 upstream을 이용한 로컬 HTTPS reverse-proxy/TLS wire 검증과 HTTP→HTTPS redirect 검증
- [ ] 실제 staging endpoint의 HTTPS reverse-proxy/TLS wire 및 인증서 갱신 검증

## 상태 표기 규칙

- `[x]`: 이 문서의 요구 증거를 모두 확보했다.
- `[-]`: 핵심 경계는 구현했지만 명시된 외부 환경·운영·확장 범위가 남아 있다.
- `[ ]`: 구현 또는 검증을 시작하지 않았거나 완료 증거가 없다.

`[-]`를 `[x]`로 바꾸려면 남은 범위를 별도 체크 항목으로 분리하고, 해당 테스트와
문서를 같은 변경 단위에 포함한다.
