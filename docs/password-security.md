# 비밀번호 보안

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** maintainers choosing password hashing parameters.
**Verified with:** `nimble passwordBenchmark`, `nimble test`

Prefer Argon2id where its memory cost fits the production login workload.
`newArgon2idPasswordHasher` keeps memory, iterations, threads, and output length
explicit. bcrypt is available through `newBcryptPasswordHasher` for compatible
deployments; PBKDF2 is a compatibility/reference option rather than a preferred
new-password default.

Store only the encoded verifier. `verifyAndRehash` lets a successful login rotate
an outdated cost or algorithm without a separate reset flow. Benchmark on the
actual deployment hardware with realistic concurrent login load, then choose a
cost that resists guessing without exhausting memory or latency budget.

Apply login throttling/rate limiting to identifiers and trusted client signals,
use generic invalid-credential responses, and record only redacted audit events.
Never add a password, hash, reset token, or benchmark sample containing real
credentials to source control or application logs.
