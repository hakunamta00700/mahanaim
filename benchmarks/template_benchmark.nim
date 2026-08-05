## Deterministic template AST/render benchmark.
##
## The benchmark exercises a collection loop, loop metadata, and automatic
## escaping. Every iteration checks the complete output so parser/renderer
## changes cannot silently turn into a successful but incorrect measurement.

import std/[monotimes, strutils, times]
import mahanaim/templates

const
  RenderCount = 10_000

proc benchmarkContext(): TemplateRenderContext =
  ## Keep the context request-local and explicit, matching the application
  ## rendering contract instead of using hidden global template state.
  result = newTemplateRenderContext()
  result.addCollection("items", @[
    newTemplateContext([("name", "<Ada>")]),
    newTemplateContext([("name", "Grace")]),
    newTemplateContext([("name", "Nim")])])

proc main() =
  let engine = newTemplateEngine()
  engine.registerTemplate("benchmark", "<ul>{% for item in items %}" &
    "<li>{{ loop.index }}:{{ item.name }}</li>{% endfor %}</ul>")
  let context = benchmarkContext()
  let expected = "<ul><li>1:&lt;Ada&gt;</li><li>2:Grace</li>" &
    "<li>3:Nim</li></ul>"
  var rendered = 0
  var renderedBytes = 0
  let started = getMonoTime()
  for _ in 0 ..< RenderCount:
    let output = engine.render("benchmark", context)
    doAssert output == expected
    doAssert output.contains("&lt;Ada&gt;")
    inc rendered
    renderedBytes += output.len
  let elapsed = getMonoTime() - started

  ## No latency threshold is enforced because CI hosts differ; correctness of
  ## the representative output is the invariant this benchmark protects.
  doAssert rendered == RenderCount
  doAssert renderedBytes == RenderCount * expected.len
  echo "renders=" & $rendered &
    " rendered_bytes=" & $renderedBytes &
    " elapsed_ms=" & $elapsed.inMilliseconds

when isMainModule:
  main()
