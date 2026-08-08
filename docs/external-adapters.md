# 외부 adapter

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** developers bridging a provider into a Mahanaim contract.
**Verified with:** contract tests plus provider-specific live evidence.

Template, storage/cache, database, authentication, channel, and durable-job
adapters use narrow framework-neutral contracts. The application chooses and
configures a concrete provider. An adapter owns provider translation, bounded
retry, and error classification; it must not silently report a failed external
operation as a framework success.

The application owns endpoint/credential selection, TLS, secret rotation,
availability policy, monitoring, and deployment recovery. Keep provider payloads
and credentials out of errors/logs, close resources at the declared owner
boundary, and support cancellation only where the provider contract safely allows
it. A local callback/in-memory adapter is not proof of production provider wire
semantics.
