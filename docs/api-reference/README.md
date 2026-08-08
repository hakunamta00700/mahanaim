# Public API reference

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](../support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](../support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](../index.md) · [지원 매트릭스](../support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](../support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

This reference is maintained from public `*` exports in `src/mahanaim` and the
compile contract in `tests/test_public_api_compile.nim`. `nimble publicApiCheck`
is the compatibility gate; `nimble docsExamples` verifies the minimal public
application example.

| Area | Reference | Source boundary |
| --- | --- | --- |
| application and HTTP | [core API](core.md) | `src/mahanaim/core.nim`, `application.nim`, `router.nim` |
| validation and response | [core API](core.md) | `validation.nim`, `response_policy.nim` |
| extension points | [extension guide](../extension-authoring.md) | public Application plugin/module APIs |
| every umbrella export | [public module map](public-modules.md) | `src/mahanaim.nim` |

New public exports require a brief, parameter/return contract, ownership and
lifecycle notes, error behavior, and a minimum example here or in its feature
guide. Deliberately excluded internal helpers must remain unexported; a public
export with no documented surface is a documentation defect.
