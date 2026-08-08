# Authorization

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** developers protecting routes, Admin resources, and individual objects.
**Verified with:** `nimble test`

`AuthorizationPolicy` is explicit and route guards are ordinary middleware. Set
roles/groups from verified identity data, then apply the narrowest guard to a
route group or individual endpoint. Object policy must evaluate the loaded
resource and `request.auth`, not a client-supplied owner identifier.

Design with least privilege: define a reader role for safe views, an editor role
for mutation, and a separate administrator role for operational actions. Deny
by default. Apply the same rule to API, HTML, background job, and Admin entry
points so one representation cannot bypass another.

Authorization failure should be a generic 403 (or an intentional 404 where
resource enumeration must be hidden), with a redacted audit record. Test an
anonymous request, authenticated wrong-role request, and authenticated
wrong-object request for every sensitive route.
