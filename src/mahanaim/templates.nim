## Small, dependency-free server-side template engine.
##
## Templates are registered as strings so storage (filesystem, embedded assets,
## database) remains an adapter concern. The core supports the deliberately
## small syntax needed by framework pages: `{{ value|filter }}`, `{% include
## "name" %}`, and `{% extends "base" %}` with `{% block name %}` overrides.

import std/[algorithm, json, os, strutils, tables]

type
  TemplateContext* = Table[string, string]
  TemplateFilter* = proc(value: string): string
  TemplateTag* = proc(arguments: seq[string], context: TemplateContext): string

  TemplateEngine* = ref object
    templates: Table[string, string]
    filters: Table[string, TemplateFilter]
    tags: Table[string, TemplateTag]
    ## Locale catalogs are kept separate from template source so deployment
    ## can replace translations without changing rendering or escaping.
    translations: Table[string, Table[string, string]]
    defaultLocale*: string
    maxInheritanceDepth*: int

proc escapeHtml*(value: string): string =
  ## Escape before output so untrusted context values cannot become markup.
  result = value.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")
  result = result.replace("'", "&#39;")

proc newTemplateEngine*(maxInheritanceDepth = 16): TemplateEngine =
  ## A finite depth also bounds accidental include/extends recursion.
  if maxInheritanceDepth < 1:
    raise newException(ValueError, "Template depth must be positive")
  new(result)
  result.templates = initTable[string, string]()
  result.filters = initTable[string, TemplateFilter]()
  result.tags = initTable[string, TemplateTag]()
  result.translations = initTable[string, Table[string, string]]()
  result.defaultLocale = "en"
  result.maxInheritanceDepth = maxInheritanceDepth
  result.filters["upper"] = proc(value: string): string = value.toUpperAscii()
  result.filters["lower"] = proc(value: string): string = value.toLowerAscii()
  result.filters["trim"] = proc(value: string): string = value.strip()

proc registerTemplate*(engine: TemplateEngine, name, source: string) =
  ## Duplicate names are rejected so plugin load order cannot silently replace
  ## a security-sensitive layout or partial.
  if engine.isNil or name.strip().len == 0:
    raise newException(ValueError, "Template engine and name are required")
  if source.len == 0:
    raise newException(ValueError, "Template source cannot be empty")
  if engine.templates.hasKey(name):
    raise newException(ValueError, "Duplicate template: " & name)
  engine.templates[name] = source

proc registerFilter*(engine: TemplateEngine, name: string,
                      filter: TemplateFilter) =
  ## Filters transform text before the final mandatory HTML escaping step.
  if engine.isNil or name.strip().len == 0 or filter.isNil:
    raise newException(ValueError, "Template filter name and callback are required")
  if engine.filters.hasKey(name):
    raise newException(ValueError, "Duplicate template filter: " & name)
  engine.filters[name] = filter

proc registerTag*(engine: TemplateEngine, name: string, tag: TemplateTag) =
  ## Tags are the explicit extension point for application helpers. A tag
  ## receives parsed arguments and a context snapshot, while the renderer
  ## retains ownership of escaping and template state.
  if engine.isNil or name.strip().len == 0 or tag.isNil:
    raise newException(ValueError, "Template tag name and callback are required")
  if engine.tags.hasKey(name):
    raise newException(ValueError, "Duplicate template tag: " & name)
  engine.tags[name] = tag

proc registerTranslation*(engine: TemplateEngine, locale, key, value: string) =
  ## Translation keys are explicit and duplicate registration is rejected so
  ## plugin load order cannot silently alter user-visible security messages.
  if engine.isNil or locale.strip().len == 0 or key.strip().len == 0:
    raise newException(ValueError, "Translation locale and key are required")
  if not engine.translations.hasKey(locale):
    engine.translations[locale] = initTable[string, string]()
  if engine.translations[locale].hasKey(key):
    raise newException(ValueError, "Duplicate translation: " & locale & ":" & key)
  engine.translations[locale][key] = value

proc loadTranslationFile*(engine: TemplateEngine, locale, path: string) =
  ## Filesystem loading is deliberately an adapter-sized operation: the
  ## renderer still owns catalog validation and duplicate policy, while an
  ## embedding application can choose when and how to discover files.
  if engine.isNil or locale.strip().len == 0:
    raise newException(ValueError, "Translation engine and locale are required")
  if path.strip().len == 0 or not fileExists(path):
    raise newException(ValueError, "Translation catalog does not exist: " & path)
  let document = try:
    parseJson(readFile(path))
  except CatchableError as error:
    raise newException(ValueError,
      "Invalid translation catalog: " & error.msg)
  if document.kind != JObject:
    raise newException(ValueError,
      "Translation catalog must contain a JSON object")
  ## Register one key at a time so malformed values and duplicate keys cannot
  ## partially bypass the same policy used by programmatic registration.
  for key, value in document.pairs:
    if value.kind != JString:
      raise newException(ValueError,
        "Translation value must be a string: " & locale & ":" & key)
    engine.registerTranslation(locale, key, value.getStr())

proc loadTranslationDirectory*(engine: TemplateEngine, directory: string,
                               extension = ".json") =
  ## Discover one catalog per locale from a deployment-owned directory. File
  ## enumeration order is normalized before registration so duplicate keys and
  ## malformed catalogs fail deterministically across operating systems.
  if engine.isNil or directory.strip().len == 0:
    raise newException(ValueError,
      "Template engine and translation directory are required")
  if not dirExists(directory):
    raise newException(ValueError,
      "Translation directory does not exist: " & directory)
  var normalizedExtension = extension.strip().toLowerAscii()
  if normalizedExtension.len == 0:
    normalizedExtension = ".json"
  elif normalizedExtension[0] != '.':
    normalizedExtension = "." & normalizedExtension
  var catalogs: seq[string] = @[]
  for path in walkFiles(directory / "*" & normalizedExtension):
    if fileExists(path):
      catalogs.add(path)
  catalogs.sort()
  for path in catalogs:
    let locale = splitFile(path).name
    if locale.strip().len == 0:
      raise newException(ValueError,
        "Translation catalog locale cannot be empty: " & path)
    engine.loadTranslationFile(locale, path)

proc translate*(engine: TemplateEngine, key: string, locale = ""): string =
  ## Missing locale entries fall back to the default catalog and finally the
  ## key itself, making incomplete catalogs safe during incremental rollout.
  if engine.isNil or key.strip().len == 0:
    return key
  let selected = if locale.strip().len > 0: locale else: engine.defaultLocale
  if engine.translations.hasKey(selected) and
      engine.translations[selected].hasKey(key):
    return engine.translations[selected][key]
  if selected != engine.defaultLocale and
      engine.translations.hasKey(engine.defaultLocale) and
      engine.translations[engine.defaultLocale].hasKey(key):
    return engine.translations[engine.defaultLocale][key]
  key

proc templateSource(engine: TemplateEngine, name: string): string =
  if not engine.templates.hasKey(name):
    raise newException(ValueError, "Template not found: " & name)
  engine.templates[name]

type BlockMap = Table[string, string]

proc collectBlocks(source: string): BlockMap =
  ## Extract direct block bodies while preserving their source text for a later
  ## rendering pass. Nested blocks are intentionally not implicit magic.
  result = initTable[string, string]()
  var cursor = 0
  const openPrefix = "{% block "
  const closeMarker = "{% endblock %}"
  while true:
    let open = source.find(openPrefix, cursor)
    if open < 0:
      break
    let openEnd = source.find("%}", open + openPrefix.len)
    if openEnd < 0:
      raise newException(ValueError, "Unclosed template block")
    let name = source[open + openPrefix.len ..< openEnd].strip()
    if name.len == 0:
      raise newException(ValueError, "Template block name cannot be empty")
    let close = source.find(closeMarker, openEnd + 2)
    if close < 0:
      raise newException(ValueError, "Template block has no end marker")
    result[name] = source[openEnd + 2 ..< close]
    cursor = close + closeMarker.len

proc mergeBlocks(parent, child: BlockMap): BlockMap =
  result = parent
  for name, source in child:
    result[name] = source

proc applyBlocks(source: string, overrides: BlockMap): string =
  ## Rebuild source instead of global replace so block names/content cannot
  ## collide with ordinary user text.
  var cursor = 0
  const openPrefix = "{% block "
  const closeMarker = "{% endblock %}"
  while true:
    let open = source.find(openPrefix, cursor)
    if open < 0:
      result.add(source[cursor .. ^1])
      break
    result.add(source[cursor ..< open])
    let openEnd = source.find("%}", open + openPrefix.len)
    if openEnd < 0:
      raise newException(ValueError, "Unclosed template block")
    let name = source[open + openPrefix.len ..< openEnd].strip()
    let close = source.find(closeMarker, openEnd + 2)
    if close < 0:
      raise newException(ValueError, "Template block has no end marker")
    if overrides.hasKey(name):
      result.add(overrides[name])
    else:
      result.add(source[openEnd + 2 ..< close])
    cursor = close + closeMarker.len

proc extendsName(source: string): string =
  const prefix = "{% extends \""
  let start = source.find(prefix)
  if start < 0:
    return ""
  let nameStart = start + prefix.len
  let nameEnd = source.find("\" %}", nameStart)
  if nameEnd < 0:
    raise newException(ValueError, "Malformed template extends directive")
  source[nameStart ..< nameEnd]

proc truthy(value: string): bool =
  ## Empty, false, no, off, and zero are false; other values are true.
  let normalized = value.strip().toLowerAscii()
  normalized notin ["", "0", "false", "no", "off"]

proc renderConditionals(engine: TemplateEngine, source: string,
                        context: TemplateContext, depth: int): string =
  ## Resolve nested `{% if %}` blocks with a depth-bounded scanner. A scanner
  ## is used instead of greedy substring replacement so nested endif markers
  ## cannot consume their parent's block.
  if depth > engine.maxInheritanceDepth:
    raise newException(ValueError, "Template conditional depth exceeded")
  var cursor = 0
  const ifPrefix = "{% if "
  const elseMarker = "{% else %}"
  const endMarker = "{% endif %}"
  while true:
    let start = source.find(ifPrefix, cursor)
    if start < 0:
      result.add(source[cursor .. ^1])
      break
    result.add(source[cursor ..< start])
    let openEnd = source.find("%}", start + ifPrefix.len)
    if openEnd < 0:
      raise newException(ValueError, "Malformed template if directive")
    let condition = source[start + ifPrefix.len ..< openEnd].strip()
    if condition.len == 0:
      raise newException(ValueError, "Template if condition cannot be empty")
    var scan = openEnd + 2
    var nested = 1
    var elseStart = -1
    var endStart = -1
    while scan < source.len:
      let marker = source.find("{%", scan)
      if marker < 0:
        break
      let markerEnd = source.find("%}", marker + 2)
      if markerEnd < 0:
        raise newException(ValueError, "Malformed template control directive")
      let directive = source[marker + 2 ..< markerEnd].strip()
      if directive.startsWith("if "):
        inc nested
      elif directive == "endif":
        dec nested
        if nested == 0:
          endStart = marker
          break
      elif directive == "else" and nested == 1:
        if elseStart >= 0:
          raise newException(ValueError, "Duplicate template else directive")
        elseStart = marker
      scan = markerEnd + 2
    if endStart < 0:
      raise newException(ValueError, "Template if block has no endif")
    let bodyEnd = if elseStart >= 0: elseStart else: endStart
    let bodyStart = openEnd + 2
    let selected = if truthy(context.getOrDefault(condition)):
      source[bodyStart ..< bodyEnd]
    elif elseStart >= 0:
      source[elseStart + elseMarker.len ..< endStart]
    else:
      ""
    result.add(renderConditionals(engine, selected, context, depth + 1))
    cursor = endStart + endMarker.len

proc renderTags(engine: TemplateEngine, source: string,
                context: TemplateContext): string =
  ## Expand custom tags after structural selection. Tag output is escaped just
  ## like variable output, preventing a helper from becoming raw HTML output.
  var cursor = 0
  const tagPrefix = "{% tag "
  while true:
    let start = source.find(tagPrefix, cursor)
    if start < 0:
      result.add(source[cursor .. ^1])
      break
    result.add(source[cursor ..< start])
    let tagEnd = source.find("%}", start + tagPrefix.len)
    if tagEnd < 0:
      raise newException(ValueError, "Malformed template tag directive")
    let arguments = source[start + tagPrefix.len ..< tagEnd].strip().splitWhitespace()
    if arguments.len == 0 or not engine.tags.hasKey(arguments[0]):
      let tagName = if arguments.len > 0: arguments[0] else: ""
      raise newException(ValueError, "Template tag not found: " & tagName)
    let tagArgs = if arguments.len > 1: arguments[1 .. ^1] else: @[]
    result.add(escapeHtml(engine.tags[arguments[0]](tagArgs, context)))
    cursor = tagEnd + 2

proc renderNamed(engine: TemplateEngine, name: string,
                 context: TemplateContext, depth: int,
                 inherited: BlockMap): string

proc renderFragment(engine: TemplateEngine, source: string,
                    context: TemplateContext, depth: int): string =
  ## Includes are expanded before variables, allowing partials to use the same
  ## context while keeping the recursion limit centralized.
  if depth > engine.maxInheritanceDepth:
    raise newException(ValueError, "Template recursion depth exceeded")
  let structured = renderConditionals(engine, source, context, depth)
  var cursor = 0
  const includePrefix = "{% include \""
  while true:
    let includeStart = structured.find(includePrefix, cursor)
    if includeStart < 0:
      result.add(structured[cursor .. ^1])
      break
    result.add(structured[cursor ..< includeStart])
    let nameStart = includeStart + includePrefix.len
    let nameEnd = structured.find("\" %}", nameStart)
    if nameEnd < 0:
      raise newException(ValueError, "Malformed template include directive")
    result.add(renderNamed(engine, structured[nameStart ..< nameEnd],
      context, depth + 1, initTable[string, string]()))
    cursor = nameEnd + 4
  var rendered = renderTags(engine, result, context)
  result = ""
  cursor = 0
  while true:
    let variableStart = rendered.find("{{", cursor)
    if variableStart < 0:
      result.add(rendered[cursor .. ^1])
      break
    result.add(rendered[cursor ..< variableStart])
    let variableEnd = rendered.find("}}", variableStart + 2)
    if variableEnd < 0:
      raise newException(ValueError, "Unclosed template variable")
    let expression = rendered[variableStart + 2 ..< variableEnd]
    let parts = expression.split('|')
    let key = parts[0].strip()
    var value = context.getOrDefault(key, "")
    for index in 1 ..< parts.len:
      let filterName = parts[index].strip()
      if not engine.filters.hasKey(filterName):
        raise newException(ValueError, "Template filter not found: " & filterName)
      value = engine.filters[filterName](value)
    result.add(escapeHtml(value))
    cursor = variableEnd + 2

proc renderNamed(engine: TemplateEngine, name: string,
                 context: TemplateContext, depth: int,
                 inherited: BlockMap): string =
  if depth > engine.maxInheritanceDepth:
    raise newException(ValueError, "Template inheritance depth exceeded")
  let source = engine.templateSource(name)
  let localBlocks = collectBlocks(source)
  let parent = extendsName(source)
  if parent.len > 0:
    return renderNamed(engine, parent, context, depth + 1,
      mergeBlocks(inherited, localBlocks))
  let materialized = applyBlocks(source, mergeBlocks(localBlocks, inherited))
  renderFragment(engine, materialized, context, depth)

proc render*(engine: TemplateEngine, name: string,
             context: TemplateContext = initTable[string, string]()): string =
  ## Public rendering entry point; all output passes through auto-escaping.
  if engine.isNil:
    raise newException(ValueError, "Template engine is required")
  renderNamed(engine, name, context, 0, initTable[string, string]())
