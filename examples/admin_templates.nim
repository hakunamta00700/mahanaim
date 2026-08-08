## Executable Admin global/resource template overrides and legacy formLayout.

import std/[asyncdispatch, httpcore, strutils, tables]
import mahanaim

var metadata = newModelMetadata("TemplateItem", "template_items")
metadata.addField(newModelField("id", modelInteger, primaryKey = true))
metadata.addField(newModelField("title", modelString))

let admin = newAdminRegistry()
admin.registerAdminTemplate("admin/list",
  "<main data-template=\"global-list\">{{ resource_name }}</main>")
admin.registerAdminTemplate("admin/items/list",
  "<main data-template=\"resource-list\">{{ resource_name }}</main>")

proc authorize(request: Request): bool {.gcsafe.} =
  request.headers.getOrDefault("x-admin") == "yes"

let legacyLayout: AdminFormLayoutRenderer = proc(
    context: AdminFormLayoutContext): Response {.gcsafe.} =
  htmlResponse("<section data-template=\"legacy-layout\">" &
    context.resourceName & "</section>")

admin.registerAdminResource("items", "/admin/items", metadata,
  newInMemoryResourceStore(metadata), authorize)
admin.registerAdminResource("other", "/admin/other", metadata,
  newInMemoryResourceStore(metadata), authorize)
admin.registerAdminResource("legacy", "/admin/legacy", metadata,
  newInMemoryResourceStore(metadata), authorize, formLayout = legacyLayout)

let app = newApplication()
registerAdminRoutes(app, admin)

proc htmlRequest(path: string): Request =
  result = newRequest("GET", path)
  result.headers["x-admin"] = "yes"
  result.headers["accept"] = "text/html"

let resourceList = waitFor app.dispatch(htmlRequest("/admin/items"))
doAssert resourceList.status == Http200
doAssert resourceList.body.contains("data-template=\"resource-list\"")

let globalList = waitFor app.dispatch(htmlRequest("/admin/other"))
doAssert globalList.status == Http200
doAssert globalList.body.contains("data-template=\"global-list\"")

let legacyForm = waitFor app.dispatch(htmlRequest("/admin/legacy/new"))
doAssert legacyForm.status == Http200
doAssert legacyForm.body.contains("data-template=\"legacy-layout\"")
echo "admin-templates-ok"
