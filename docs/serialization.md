# Serialization

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** API authors translating model metadata into an explicit wire response.
**Verified with:** `nimble test`

`serializeModel`, `serializePatch`, `serializeModelGraph`, and
`serializeProjection` derive output from `ModelMetadata`. Use a projection for
each public endpoint; it prevents an internal or sensitive field from becoming a
response merely because it exists on a model.

The standard contract handles scalar JSON values and metadata-defined enum,
date/time, UUID, file, reference, and collection shapes. A custom codec belongs
in the serialization adapter registry, with a test for encode and decode failure.
Request input is not automatically a response DTO: validate input, perform the
domain work, then choose a response projection.

Never serialize password hashes, reset tokens, session data, provider credentials,
or raw upload paths. Treat renamed and deprecated response members as versioned
API contracts and document their replacement before removal.
