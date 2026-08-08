## Executable authorized Admin CRUD and audit event example.

import std/[asyncdispatch, httpcore, json, strutils, tables]
import mahanaim

var metadata = newModelMetadata("ExampleItem", "example_items")
metadata.addField(newModelField("id", modelInteger, primaryKey = true))
metadata.addField(newModelField("title", modelString))

let admin = newAdminRegistry()
proc authorize(request: Request): bool {.gcsafe.} =
  request.auth.authenticated and request.auth.subject == "admin-1"
admin.registerAdminResource("items", "/admin/items", metadata,
  newInMemoryResourceStore(metadata), authorize)

let app = newApplication()
registerAdminRoutes(app, admin)

let denied = waitFor app.dispatch(newRequest("GET", "/admin/items"))
doAssert denied.status == Http403

var createRequest = newRequest("POST", "/admin/items", "{\"title\":\"first\"}")
createRequest.auth = AuthContext(authenticated: true, subject: "admin-1")
let created = waitFor app.dispatch(createRequest)
doAssert created.status == Http201
let id = parseJson(created.body)["id"].getInt()

var htmlList = newRequest("GET", "/admin/items")
htmlList.headers["accept"] = "text/html"
htmlList.auth = createRequest.auth
doAssert (waitFor app.dispatch(htmlList)).status == Http200

var formUpdate = newRequest("POST", "/admin/items/" & $id, "title=updated")
formUpdate.headers["content-type"] = "application/x-www-form-urlencoded"
formUpdate.headers["accept"] = "text/html"
formUpdate.auth = createRequest.auth
doAssert (waitFor app.dispatch(formUpdate)).status == Http302

var htmlDetail = newRequest("GET", "/admin/items/" & $id)
htmlDetail.headers["accept"] = "text/html"
htmlDetail.auth = createRequest.auth
let detail = waitFor app.dispatch(htmlDetail)
doAssert detail.status == Http200
doAssert detail.body.contains("updated")

var formDelete = newRequest("POST", "/admin/items/" & $id & "/delete")
formDelete.headers["accept"] = "text/html"
formDelete.auth = createRequest.auth
doAssert (waitFor app.dispatch(formDelete)).status == Http302

let events = admin.auditEvents()
doAssert events.len == 3
doAssert events[0].action == "create"
doAssert events[0].resource == "items"
doAssert events[0].actor == "admin-1"
doAssert events[1].action == "update"
doAssert events[2].action == "delete"
echo "admin-audit-ok"
