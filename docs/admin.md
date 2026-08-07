# Admin resources

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
