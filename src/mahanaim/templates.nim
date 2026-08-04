## Small, dependency-free server-side template engine.
##
## Templates are registered as strings so storage (filesystem, embedded assets,
## database) remains an adapter concern. The core supports the deliberately
## small syntax needed by framework pages: `{{ value|filter }}`, `{% include
## "name" %}`, and `{% extends "base" %}` with `{% block name %}` overrides.

import std/[strutils, tables]

type
  TemplateContext* = Table[string, string]
  TemplateFilter* = proc(value: string): string

  TemplateEngine* = ref object
    templates: Table[string, string]
    filters: Table[string, TemplateFilter]
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

proc renderNamed(engine: TemplateEngine, name: string,
                 context: TemplateContext, depth: int,
                 inherited: BlockMap): string

proc renderFragment(engine: TemplateEngine, source: string,
                    context: TemplateContext, depth: int): string =
  ## Includes are expanded before variables, allowing partials to use the same
  ## context while keeping the recursion limit centralized.
  if depth > engine.maxInheritanceDepth:
    raise newException(ValueError, "Template recursion depth exceeded")
  var cursor = 0
  const includePrefix = "{% include \""
  while true:
    let includeStart = source.find(includePrefix, cursor)
    if includeStart < 0:
      result.add(source[cursor .. ^1])
      break
    result.add(source[cursor ..< includeStart])
    let nameStart = includeStart + includePrefix.len
    let nameEnd = source.find("\" %}", nameStart)
    if nameEnd < 0:
      raise newException(ValueError, "Malformed template include directive")
    result.add(renderNamed(engine, source[nameStart ..< nameEnd],
      context, depth + 1, initTable[string, string]()))
    cursor = nameEnd + 4
  var rendered = result
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
