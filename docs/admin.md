# Admin resources

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** maintainers exposing authorized internal CRUD pages.
**Status:** experimental.
**Verified with:** `nimble test`

Admin is explicit: create an `AdminRegistry`, register each resource with model
metadata, a `ResourceStore`, and a mandatory authorization callback, then attach
the routes to the normal application.

```nim
let admin = newAdminRegistry(newSqliteAdminAuditStore("var/admin-audit.sqlite"))
admin.registerAdminResource("products", "/admin/products", productMetadata,
  productStore, authorize = proc(request: Request): bool = request.auth.authenticated)
registerAdminRoutes(app, admin)
```

Registered resources provide JSON CRUD and server-rendered list/create/detail/
update/delete pages. Configure `readOnlyFields`, `customColumns`, query options,
and an optional `formLayout` deliberately. Inlines use `registerAdminInline`; the
server assigns the parent field, so submitted child data cannot choose another
parent. Admin authorization and CSRF middleware remain in force for every route.

Successful mutations append an `AdminAuditEvent` containing action, resource,
identifier, and actor—not request bodies or credentials. Use SQLite audit storage
or implement `AdminAuditStore` for another append-only sink. See
[Admin operations](admin-operations.md) and [template customization](admin-template-customization.md).

## 권한·CRUD·audit 실행 예제

[`examples/admin_audit.nim`](../examples/admin_audit.nim)은 인증되지 않은 list 요청이
403인지, `admin-1`이 JSON resource를 생성·조회할 수 있는지, 그리고 audit event가
`create`/`items`/`admin-1`만 기록하는지를 검증한다. `nimble docsExamples`로 실행하면
`admin-audit-ok`를 출력한다. 이 예제의 in-memory store는 local contract 전용이며,
production audit retention/backup은 [Admin operations](admin-operations.md)이 소유한다.
