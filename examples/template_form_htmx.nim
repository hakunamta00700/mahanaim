## Executable template, server-side form, and HTMX representation example.

import std/[asyncdispatch, httpcore, options, strutils, tables]
import mahanaim

let engine = newTemplateEngine()
engine.registerTemplate("items/page", "<main data-view=\"full\">items</main>")
engine.registerTemplate("items/list", "<li data-view=\"partial\">item</li>")
let fullHtml = engine.render("items/page")
let partialHtml = engine.render("items/list")

proc items(request: Request): Future[Response] {.async, gcsafe.} =
  ## Rendering belongs to composition/template preparation here. The async
  ## route only negotiates immutable representations, so it remains GCSafe.
  return htmlJsonResponse(request, "<main data-view=\"full\">items</main>",
    "<li data-view=\"partial\">item</li>", "{\"items\":[\"item\"]}")

proc signup(request: Request): Future[Response] {.async, gcsafe.} =
  let form = bindForm(request, [stringField("email", flBody, maxLength = 254)])
  if form.errors.len > 0:
    return htmlResponse(renderForm(form, "/signup"))
  return textResponse("saved", Http201)

let app = newApplication()
app.get("/items", "items", items)
app.post("/signup", "signup", signup)

doAssert fullHtml.contains("data-view=\"full\"")
doAssert partialHtml.contains("data-view=\"partial\"")
doAssert (waitFor app.dispatch(newRequest("GET", "/items"))).body.contains("full")
var partialRequest = newRequest("GET", "/items")
partialRequest.headers["HX-Request"] = "true"
let partial = waitFor app.dispatch(partialRequest)
doAssert partial.body.contains("partial")
doAssert partial.header("Vary").get() == "Accept, HX-Request"

var jsonRequest = newRequest("GET", "/items")
jsonRequest.headers["accept"] = "application/json"
let json = waitFor app.dispatch(jsonRequest)
doAssert json.status == Http200
doAssert json.body.contains("items")

var invalidForm = newRequest("POST", "/signup", "email=" & repeat("x", 255))
invalidForm.headers["content-type"] = "application/x-www-form-urlencoded"
let invalid = waitFor app.dispatch(invalidForm)
doAssert invalid.status == Http200
doAssert invalid.body.contains("form-error")
echo "template-form-htmx-ok"
