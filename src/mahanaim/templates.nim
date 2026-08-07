## Small, dependency-free server-side template engine.
##
## Templates are registered as strings so storage (filesystem, embedded assets,
## database) remains an adapter concern. The core supports the deliberately
## small syntax needed by framework pages: `{{ value|filter }}`, `{% include
## "name" %}`, and `{% extends "base" %}` with `{% block name %}` overrides.

import std/[algorithm, json, os, strutils, tables, times]
import ./localization

type
  TemplateContext* = Table[string, string]
  TemplateCollectionProjection* = proc(
    context: TemplateContext): seq[TemplateContext]
  TemplateHelperArgumentKind* = enum
    helperLiteral
    helperContext
  TemplateHelperArgument* = object
    ## A parsed helper argument keeps literal/context provenance explicit so a
    ## helper cannot accidentally treat user data as template syntax.
    name*: string
    value*: string
    kind*: TemplateHelperArgumentKind
  TemplateHelper* = proc(arguments: seq[TemplateHelperArgument],
                         context: TemplateContext): string
  TemplateNodeKind* = enum
    ## Nodes represent syntax, not rendered text. Keeping control flow
    ## structural prevents a nested block from accidentally consuming a
    ## sibling's closing marker during a later string scan.
    templateText
    templateVariable
    templateIf
    templateFor
    templateInclude
    templateHelper
    templateTag
    templateBlock
    templateExtends
  TemplateNode* = ref object
    ## Public AST metadata is intentionally small: applications can inspect
    ## templates for tooling while rendering remains owned by TemplateEngine.
    kind*: TemplateNodeKind
    value*: string
    name*: string
    variableName*: string
    collectionName*: string
    arguments*: seq[TemplateHelperArgument]
    children*: seq[TemplateNode]
    elseChildren*: seq[TemplateNode]
  TemplateAst* = object
    ## The root owns an ordered node list; all nested block ownership is
    ## explicit in each node's children/elseChildren fields.
    nodes*: seq[TemplateNode]
  TemplateRenderContext* = object
    ## Scalar values and collections are separate so a template cannot turn a
    ## comma-separated string into an implicit data structure. Applications
    ## choose the collection shape before rendering, keeping parsing outside
    ## the template engine's security boundary.
    values*: TemplateContext
    collections*: Table[string, seq[TemplateContext]]
    ## Dynamic projections are resolved against the current scalar context.
    ## This keeps nested relation loading outside the parser while allowing a
    ## loop body to request `parent.children` for the current parent only.
    projections*: Table[string, TemplateCollectionProjection]
    ## Formatter policy is request-owned rather than global. Built-in locale
    ## helpers are enabled only when this flag is set, making an accidental
    ## server-wide locale leak impossible.
    hasLocaleFormatter*: bool
    localeFormatter*: LocaleFormatPolicy
  TemplateFilter* = proc(value: string): string
  TemplateTag* = proc(arguments: seq[string], context: TemplateContext): string

  TemplateEngine* = ref object
    templates: Table[string, string]
    filters: Table[string, TemplateFilter]
    tags: Table[string, TemplateTag]
    helpers: Table[string, TemplateHelper]
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
  result.helpers = initTable[string, TemplateHelper]()
  result.translations = initTable[string, Table[string, string]]()
  result.defaultLocale = "en"
  result.maxInheritanceDepth = maxInheritanceDepth
  result.filters["upper"] = proc(value: string): string = value.toUpperAscii()
  result.filters["lower"] = proc(value: string): string = value.toLowerAscii()
  result.filters["trim"] = proc(value: string): string = value.strip()

proc newTemplateContext*(values: openArray[(string, string)]): TemplateContext =
  ## Build a deterministic scalar context without exposing Table initialization
  ## details to application or test code.
  result = initTable[string, string]()
  for (name, value) in values:
    if name.strip().len == 0:
      raise newException(ValueError, "Template context key cannot be empty")
    result[name] = value

proc newTemplateRenderContext*(): TemplateRenderContext =
  ## A fresh render context prevents collection data leaking between renders.
  result.values = initTable[string, string]()
  result.collections = initTable[string, seq[TemplateContext]]()
  result.projections = initTable[string, TemplateCollectionProjection]()
  result.hasLocaleFormatter = false

proc setLocaleFormatter*(context: var TemplateRenderContext,
                         policy: LocaleFormatPolicy) =
  ## Attach one immutable formatter snapshot to this render. Applications can
  ## construct it from Request.locale/timezone after middleware negotiation.
  context.localeFormatter = policy
  context.hasLocaleFormatter = true

proc addCollection*(context: var TemplateRenderContext, name: string,
                    values: openArray[TemplateContext]) =
  ## Collection registration is explicit and rejects duplicate names so a
  ## plugin cannot silently replace data supplied by the application.
  if name.strip().len == 0:
    raise newException(ValueError, "Template collection name cannot be empty")
  if context.collections.hasKey(name):
    raise newException(ValueError, "Duplicate template collection: " & name)
  context.collections[name] = @values

proc addCollectionProjection*(context: var TemplateRenderContext, name: string,
                              projection: TemplateCollectionProjection) =
  ## Register one dynamic relation resolver. The resolver is called only when
  ## a template loop references its name, and receives the current context so
  ## it can use a parent identifier or any other explicitly projected value.
  if name.strip().len == 0 or projection.isNil:
    raise newException(ValueError,
      "Template collection projection name and callback are required")
  if context.collections.hasKey(name) or context.projections.hasKey(name):
    raise newException(ValueError,
      "Duplicate template collection projection: " & name)
  context.projections[name] = projection

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

proc hasTemplate*(engine: TemplateEngine, name: string): bool =
  ## Let higher-level template registries select an optional override without
  ## exposing the engine's source table for mutation.
  not engine.isNil and engine.templates.hasKey(name)

proc replaceTemplate*(engine: TemplateEngine, name, source: string) =
  ## Replace an explicitly selected template. Unlike `registerTemplate`, this
  ## is intended for an application-owned override layer (for example, a
  ## project replacing a framework-provided default layout). Callers must opt
  ## into this operation; normal registration remains duplicate-safe.
  if engine.isNil or name.strip().len == 0:
    raise newException(ValueError, "Template engine and name are required")
  if source.len == 0:
    raise newException(ValueError, "Template source cannot be empty")
  engine.templates[name] = source

proc registerTemplateFile*(engine: TemplateEngine, name, path: string) =
  ## Load one deployment-owned template while preserving the same duplicate
  ## and empty-source policy as programmatic registration. Applications choose
  ## the path; rendering continues to operate on the engine's owned snapshot.
  if path.strip().len == 0 or not fileExists(path):
    raise newException(ValueError, "Template file does not exist: " & path)
  let source = try:
    readFile(path)
  except CatchableError as error:
    raise newException(ValueError, "Template file cannot be read: " & error.msg)
  engine.registerTemplate(name, source)

proc loadTemplateDirectory*(engine: TemplateEngine, directory: string,
                            extension = ".html") =
  ## Register templates recursively using extension-free, slash-normalized
  ## paths relative to the selected root. For example,
  ## `templates/layouts/base.html` becomes `layouts/base`, which can be used by
  ## render, include, and extends without exposing an absolute filesystem path.
  if engine.isNil or directory.strip().len == 0:
    raise newException(ValueError,
      "Template engine and template directory are required")
  if not dirExists(directory):
    raise newException(ValueError,
      "Template directory does not exist: " & directory)
  var normalizedExtension = extension.strip().toLowerAscii()
  if normalizedExtension.len == 0:
    normalizedExtension = ".html"
  elif normalizedExtension[0] != '.':
    normalizedExtension = "." & normalizedExtension
  var paths: seq[string] = @[]
  for path in walkDirRec(directory):
    if fileExists(path) and splitFile(path).ext.toLowerAscii() ==
        normalizedExtension:
      paths.add(path)
  paths.sort()
  for path in paths:
    let relative = relativePath(path, directory).replace('\\', '/')
    let suffixLength = splitFile(relative).ext.len
    let name = relative[0 ..< relative.len - suffixLength]
    if name.strip().len == 0:
      raise newException(ValueError,
        "Template file name cannot be empty: " & path)
    engine.registerTemplateFile(name, path)

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

proc registerHelper*(engine: TemplateEngine, name: string,
                      helper: TemplateHelper) =
  ## Helpers are the AST-aware extension point. Unlike the legacy tag API,
  ## helpers receive named arguments with literal/context kinds already parsed.
  if engine.isNil or name.strip().len == 0 or helper.isNil:
    raise newException(ValueError, "Template helper name and callback are required")
  if name in ["format_decimal", "format_datetime"]:
    raise newException(ValueError,
      "Locale template helper name is reserved: " & name)
  if engine.helpers.hasKey(name):
    raise newException(ValueError, "Duplicate template helper: " & name)
  engine.helpers[name] = helper

proc resolveTemplateHelperArgument*(argument: TemplateHelperArgument,
                                    context: TemplateContext): string =
  ## Context lookup is explicit and bounded to the current render snapshot;
  ## literal values never perform a second lookup.
  case argument.kind
  of helperLiteral:
    argument.value
  of helperContext:
    context.getOrDefault(argument.value)

proc localeHelperArgument(arguments: openArray[TemplateHelperArgument],
                          name: string, context: TemplateContext): string =
  ## Named arguments keep formatter helpers independent from argument order;
  ## unnamed first arguments remain convenient for small templates.
  for argument in arguments:
    if argument.name == name:
      return resolveTemplateHelperArgument(argument, context)
  if name == "value" and arguments.len > 0:
    return resolveTemplateHelperArgument(arguments[0], context)
  ""

proc renderLocaleHelper(name: string,
                        arguments: openArray[TemplateHelperArgument],
                        context: TemplateContext,
                        policy: LocaleFormatPolicy): string =
  ## These helpers are built into the render context rather than registered on
  ## the shared engine, so concurrent requests can use different locales.
  case name
  of "format_decimal":
    let rawValue = localeHelperArgument(arguments, "value", context)
    if rawValue.strip().len == 0:
      raise newException(ValueError, "format_decimal requires value")
    var fractionDigits = 2
    let rawDigits = localeHelperArgument(arguments, "digits", context)
    if rawDigits.len > 0:
      try:
        fractionDigits = parseInt(rawDigits)
      except ValueError:
        raise newException(ValueError, "format_decimal digits must be an integer")
    try:
      return policy.formatDecimal(parseFloat(rawValue), fractionDigits)
    except ValueError as error:
      raise newException(ValueError, "format_decimal value is invalid: " & error.msg)
  of "format_datetime":
    let rawValue = localeHelperArgument(arguments, "value", context)
    if rawValue.strip().len == 0:
      raise newException(ValueError, "format_datetime requires value")
    try:
      let parsed = parse(rawValue, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
      return policy.formatDateTime(parsed)
    except ValueError as error:
      raise newException(ValueError,
        "format_datetime value must be an ISO UTC instant: " & error.msg)
  else:
    raise newException(ValueError, "Unknown locale template helper: " & name)

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
type AstBlockMap = Table[string, seq[TemplateNode]]

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

proc renderConditionals(engine: TemplateEngine, source: string,
                        context: TemplateContext,
                        collections: Table[string, seq[TemplateContext]],
                        projections: Table[string, TemplateCollectionProjection],
                        depth: int): string

proc renderFragment(engine: TemplateEngine, source: string,
                    context: TemplateContext,
                    collections: Table[string, seq[TemplateContext]],
                    projections: Table[string, TemplateCollectionProjection],
                    depth: int): string

proc renderLoops(engine: TemplateEngine, source: string,
                 context: TemplateContext,
                 collections: Table[string, seq[TemplateContext]],
                 projections: Table[string, TemplateCollectionProjection],
                 depth: int): string =
  ## Expand `{% for item in collection %}` with a marker scanner. Matching end
  ## markers are counted instead of found with a greedy search, so nested loops
  ## cannot consume their parent's boundary. Each iteration receives copied
  ## scalar values under `item.field`, preserving auto-escaping and tag APIs.
  if depth > engine.maxInheritanceDepth:
    raise newException(ValueError, "Template loop depth exceeded")
  var cursor = 0
  const forPrefix = "{% for "
  const endMarker = "{% endfor %}"
  while true:
    let start = source.find(forPrefix, cursor)
    if start < 0:
      result.add(source[cursor .. ^1])
      break
    result.add(source[cursor ..< start])
    let openEnd = source.find("%}", start + forPrefix.len)
    if openEnd < 0:
      raise newException(ValueError, "Malformed template for directive")
    let parts = source[start + forPrefix.len ..< openEnd].strip().splitWhitespace()
    if parts.len != 3 or parts[1] != "in" or parts[0].len == 0 or
        parts[2].len == 0:
      raise newException(ValueError,
        "Template for directive must use: for item in collection")
    let variableName = parts[0]
    let collectionName = parts[2]
    if not collections.hasKey(collectionName) and
        not projections.hasKey(collectionName):
      raise newException(ValueError,
        "Template collection not found: " & collectionName)
    var scan = openEnd + 2
    var nested = 1
    var endStart = -1
    while scan < source.len:
      let marker = source.find("{%", scan)
      if marker < 0:
        break
      let markerEnd = source.find("%}", marker + 2)
      if markerEnd < 0:
        raise newException(ValueError, "Malformed template control directive")
      let directive = source[marker + 2 ..< markerEnd].strip()
      if directive.startsWith("for "):
        inc nested
      elif directive == "endfor":
        dec nested
        if nested == 0:
          endStart = marker
          break
      scan = markerEnd + 2
    if endStart < 0:
      raise newException(ValueError, "Template for block has no endfor")
    let body = source[openEnd + 2 ..< endStart]
    let items = if collections.hasKey(collectionName):
      collections[collectionName]
    else:
      projections[collectionName](context)
    for item in items:
      var itemContext = context
      for key, value in item:
        itemContext[variableName & "." & key] = value
      ## Render the complete fragment per item so variable substitution keeps
      ## the item's copied context instead of falling back to the outer row.
      result.add(renderFragment(engine, body, itemContext, collections,
        projections, depth + 1))
    cursor = endStart + endMarker.len

proc truthy(value: string): bool =
  ## Empty, false, no, off, and zero are false; other values are true.
  let normalized = value.strip().toLowerAscii()
  normalized notin ["", "0", "false", "no", "off"]

proc renderConditionals(engine: TemplateEngine, source: string,
                        context: TemplateContext,
                        collections: Table[string, seq[TemplateContext]],
                        projections: Table[string, TemplateCollectionProjection],
                        depth: int): string =
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
    let expanded = renderLoops(engine, selected, context, collections,
      projections, depth + 1)
    result.add(renderConditionals(engine, expanded, context, collections,
      projections, depth + 1))
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

type TemplateHelperLexeme = object
  value: string
  quoted: bool

proc lexTemplateHelperArguments(source: string): seq[TemplateHelperLexeme] =
  ## Parse one helper directive without evaluating it. Quoted segments may
  ## contain whitespace; a backslash escapes the following character inside a
  ## quoted segment. Keeping this lexer private prevents the public helper API
  ## from depending on template source representation details.
  var current = ""
  var quoted = false
  var quote: char = '\0'
  var escaped = false
  for character in source:
    if escaped:
      current.add(character)
      escaped = false
    elif quote != '\0' and character == '\\':
      escaped = true
    elif quote != '\0':
      if character == quote:
        quote = '\0'
      else:
        current.add(character)
    elif character in {'"', '\''}:
      quote = character
      quoted = true
    elif character.isSpaceAscii():
      if current.len > 0 or quoted:
        result.add(TemplateHelperLexeme(value: current, quoted: quoted))
        current = ""
        quoted = false
    else:
      current.add(character)
  if escaped or quote != '\0':
    raise newException(ValueError, "Malformed template helper argument")
  if current.len > 0 or quoted:
    result.add(TemplateHelperLexeme(value: current, quoted: quoted))

proc parseTemplateHelperDirective(source: string): tuple[
    name: string, arguments: seq[TemplateHelperArgument]] =
  ## Build a small AST node list from `helper name=value` syntax. Bare values
  ## are context expressions; quoted values are immutable literals.
  let lexemes = lexTemplateHelperArguments(source)
  if lexemes.len == 0 or lexemes[0].value.len == 0:
    raise newException(ValueError, "Template helper name is required")
  result.name = lexemes[0].value
  if lexemes.len > 1:
    for lexeme in lexemes[1 .. ^1]:
      let separator = lexeme.value.find('=')
      if separator == 0:
        raise newException(ValueError,
          "Template helper argument name is required")
      let argumentName = if separator < 0: "" else: lexeme.value[0 ..< separator]
      let rawValue = if separator < 0: lexeme.value else:
        lexeme.value[separator + 1 .. ^1]
      if rawValue.len == 0 and not lexeme.quoted:
        raise newException(ValueError,
          "Template helper context argument cannot be empty")
      result.arguments.add(TemplateHelperArgument(name: argumentName,
        value: rawValue,
        kind: if lexeme.quoted: helperLiteral else: helperContext))

type
  TemplateParseMode = enum
    parseRoot
    parseIf
    parseFor
    parseBlock
  TemplateParseStop = enum
    parseNoStop
    parseElse
    parseElif
    parseEndIf
    parseEndFor
    parseEndBlock
  TemplateParseResult = object
    nodes: seq[TemplateNode]
    cursor: int
    stop: TemplateParseStop
    ## An elif stop carries its condition to the recursive conditional builder.
    ## Keeping it on the parser result avoids adding a second AST node kind;
    ## the renderer can treat the chain as ordinary nested `templateIf` nodes.
    condition: string

proc quotedTemplateName(source: string): string =
  ## Includes and extends accept one quoted template name. Keeping this
  ## validation in the parser prevents path-like control text from being
  ## interpreted differently by each renderer phase.
  let lexemes = lexTemplateHelperArguments(source)
  if lexemes.len != 1 or not lexemes[0].quoted or lexemes[0].value.len == 0:
    raise newException(ValueError,
      "Template name must be one quoted argument")
  lexemes[0].value

proc parseTemplateNodes(source: string, cursor: int,
                        mode: TemplateParseMode): TemplateParseResult

proc parseConditional(source: string, cursor: int,
                      condition: string): tuple[node: TemplateNode,
                                                cursor: int] =
  ## Build one if/elif/else chain recursively. An `elif` becomes the single
  ## node in the preceding branch's elseChildren, preserving short-circuit
  ## evaluation and the existing TemplateNode public shape.
  let body = parseTemplateNodes(source, cursor, parseIf)
  if body.stop notin {parseElse, parseElif, parseEndIf}:
    raise newException(ValueError, "Template if block has no endif")
  result.node = TemplateNode(kind: templateIf, value: condition,
    children: body.nodes, elseChildren: @[])
  case body.stop
  of parseElse:
    let alternate = parseTemplateNodes(source, body.cursor, parseIf)
    if alternate.stop != parseEndIf:
      raise newException(ValueError, "Template if block has no endif")
    result.node.elseChildren = alternate.nodes
    result.cursor = alternate.cursor
  of parseElif:
    let nested = parseConditional(source, body.cursor, body.condition)
    result.node.elseChildren = @[nested.node]
    result.cursor = nested.cursor
  of parseEndIf:
    result.cursor = body.cursor
  else:
    raise newException(ValueError, "Template if block has no endif")

proc parseTemplateNodes(source: string, cursor: int,
                        mode: TemplateParseMode): TemplateParseResult =
  ## Recursive descent over the two delimiter kinds. Each recursive call owns
  ## one block and returns only its matching close marker, so crossing `endif`,
  ## `endfor`, or `endblock` directives become deterministic errors.
  var position = cursor
  while position < source.len:
    let variableStart = source.find("{{", position)
    let directiveStart = source.find("{%", position)
    var nextStart = -1
    if variableStart >= 0 and directiveStart >= 0:
      nextStart = min(variableStart, directiveStart)
    elif variableStart >= 0:
      nextStart = variableStart
    elif directiveStart >= 0:
      nextStart = directiveStart
    if nextStart < 0:
      if position < source.len:
        result.nodes.add(TemplateNode(kind: templateText,
          value: source[position .. ^1]))
      result.cursor = source.len
      result.stop = parseNoStop
      return
    if nextStart > position:
      result.nodes.add(TemplateNode(kind: templateText,
        value: source[position ..< nextStart]))
    if nextStart == variableStart:
      let close = source.find("}}", nextStart + 2)
      if close < 0:
        raise newException(ValueError, "Unclosed template variable")
      let expression = source[nextStart + 2 ..< close].strip()
      if expression.len == 0:
        raise newException(ValueError, "Template variable expression is empty")
      result.nodes.add(TemplateNode(kind: templateVariable, value: expression))
      position = close + 2
      continue

    let close = source.find("%}", nextStart + 2)
    if close < 0:
      raise newException(ValueError, "Malformed template control directive")
    let directive = source[nextStart + 2 ..< close].strip()
    let after = close + 2
    if directive == "else":
      if mode notin {parseIf, parseFor}:
        raise newException(ValueError, "Unexpected template else directive")
      result.cursor = after
      result.stop = parseElse
      return
    if directive.startsWith("elif "):
      if mode != parseIf:
        raise newException(ValueError, "Unexpected template elif directive")
      let condition = directive[5 .. ^1].strip()
      if condition.len == 0:
        raise newException(ValueError, "Template elif condition cannot be empty")
      result.cursor = after
      result.stop = parseElif
      result.condition = condition
      return
    if directive == "endif":
      if mode != parseIf:
        raise newException(ValueError, "Unexpected template endif directive")
      result.cursor = after
      result.stop = parseEndIf
      return
    if directive == "endfor":
      if mode != parseFor:
        raise newException(ValueError, "Unexpected template endfor directive")
      result.cursor = after
      result.stop = parseEndFor
      return
    if directive == "endblock":
      if mode != parseBlock:
        raise newException(ValueError, "Unexpected template endblock directive")
      result.cursor = after
      result.stop = parseEndBlock
      return

    if directive.startsWith("if "):
      let condition = directive[3 .. ^1].strip()
      if condition.len == 0:
        raise newException(ValueError, "Template if condition cannot be empty")
      let conditional = parseConditional(source, after, condition)
      result.nodes.add(conditional.node)
      position = conditional.cursor
      continue

    if directive.startsWith("for "):
      let parts = directive[4 .. ^1].strip().splitWhitespace()
      if parts.len != 3 or parts[1] != "in" or parts[0].len == 0 or
          parts[2].len == 0:
        raise newException(ValueError,
          "Template for directive must use: for item in collection")
      let body = parseTemplateNodes(source, after, parseFor)
      if body.stop notin {parseElse, parseEndFor}:
        raise newException(ValueError, "Template for block has no endfor")
      var node = TemplateNode(kind: templateFor,
        variableName: parts[0], collectionName: parts[2],
        children: body.nodes, elseChildren: @[])
      if body.stop == parseElse:
        ## A loop's else branch is selected only when the resolved collection
        ## is empty. Parsing it as another parseFor block keeps nested loops
        ## and their end markers owned by the same recursive boundary.
        let alternate = parseTemplateNodes(source, body.cursor, parseFor)
        if alternate.stop != parseEndFor:
          raise newException(ValueError, "Template for block has no endfor")
        node.elseChildren = alternate.nodes
        position = alternate.cursor
      else:
        position = body.cursor
      result.nodes.add(node)
      continue

    if directive.startsWith("include "):
      result.nodes.add(TemplateNode(kind: templateInclude,
        name: quotedTemplateName(directive[8 .. ^1].strip())))
      position = after
      continue

    if directive.startsWith("extends "):
      result.nodes.add(TemplateNode(kind: templateExtends,
        name: quotedTemplateName(directive[8 .. ^1].strip())))
      position = after
      continue

    if directive.startsWith("block "):
      let blockName = directive[6 .. ^1].strip()
      if blockName.len == 0:
        raise newException(ValueError, "Template block name cannot be empty")
      let body = parseTemplateNodes(source, after, parseBlock)
      if body.stop != parseEndBlock:
        raise newException(ValueError, "Template block has no endblock")
      result.nodes.add(TemplateNode(kind: templateBlock, name: blockName,
        children: body.nodes))
      position = body.cursor
      continue

    if directive.startsWith("helper "):
      let parsed = parseTemplateHelperDirective(directive[7 .. ^1].strip())
      result.nodes.add(TemplateNode(kind: templateHelper, name: parsed.name,
        arguments: parsed.arguments))
      position = after
      continue

    if directive.startsWith("tag "):
      let lexemes = lexTemplateHelperArguments(directive[4 .. ^1].strip())
      if lexemes.len == 0 or lexemes[0].value.len == 0:
        raise newException(ValueError, "Template tag name is required")
      var arguments: seq[TemplateHelperArgument] = @[]
      if lexemes.len > 1:
        for lexeme in lexemes[1 .. ^1]:
          arguments.add(TemplateHelperArgument(name: "", value: lexeme.value,
            kind: if lexeme.quoted: helperLiteral else: helperContext))
      result.nodes.add(TemplateNode(kind: templateTag,
        name: lexemes[0].value, arguments: arguments))
      position = after
      continue

    raise newException(ValueError, "Unknown template directive: " & directive)
  result.cursor = position
  result.stop = parseNoStop

proc parseTemplate*(source: string): TemplateAst =
  ## Parse a complete source into an owned AST. Rendering calls this same
  ## public contract, so tooling and runtime cannot disagree about nesting.
  let parsed = parseTemplateNodes(source, 0, parseRoot)
  if parsed.stop != parseNoStop:
    raise newException(ValueError, "Unexpected template closing directive")
  TemplateAst(nodes: parsed.nodes)

proc renderHelpers(engine: TemplateEngine, source: string,
                   context: TemplateContext): string =
  ## Expand AST-aware helpers before legacy tags. Both extension points return
  ## escaped text, so application callbacks cannot inject raw markup by
  ## accident; a dedicated safe-html contract can be added later if needed.
  var cursor = 0
  const helperPrefix = "{% helper "
  while true:
    let start = source.find(helperPrefix, cursor)
    if start < 0:
      result.add(source[cursor .. ^1])
      break
    result.add(source[cursor ..< start])
    let helperEnd = source.find("%}", start + helperPrefix.len)
    if helperEnd < 0:
      raise newException(ValueError, "Malformed template helper directive")
    let parsed = parseTemplateHelperDirective(
      source[start + helperPrefix.len ..< helperEnd].strip())
    if not engine.helpers.hasKey(parsed.name):
      raise newException(ValueError, "Template helper not found: " & parsed.name)
    result.add(escapeHtml(engine.helpers[parsed.name](parsed.arguments, context)))
    cursor = helperEnd + 2

proc renderNamed(engine: TemplateEngine, name: string,
                 context: TemplateContext,
                 collections: Table[string, seq[TemplateContext]], depth: int,
                 projections: Table[string, TemplateCollectionProjection],
                 inherited: AstBlockMap,
                 hasLocaleFormatter: bool,
                 localeFormatter: LocaleFormatPolicy): string

proc renderTemplateVariable(engine: TemplateEngine, expression: string,
                            context: TemplateContext): string =
  ## Resolve a variable expression only after the AST has selected its node.
  ## Filters remain ordered and the final escape is applied exactly once.
  let parts = expression.split('|')
  var value = context.getOrDefault(parts[0].strip(), "")
  if parts.len > 1:
    for index in 1 ..< parts.len:
      let filterName = parts[index].strip()
      if not engine.filters.hasKey(filterName):
        raise newException(ValueError, "Template filter not found: " & filterName)
      value = engine.filters[filterName](value)
  escapeHtml(value)

proc renderAstNodes(engine: TemplateEngine, nodes: seq[TemplateNode],
                    context: TemplateContext,
                    collections: Table[string, seq[TemplateContext]],
                    projections: Table[string, TemplateCollectionProjection],
                    depth: int,
                    hasLocaleFormatter: bool,
                    localeFormatter: LocaleFormatPolicy): string =
  ## Render typed nodes recursively. This is the single structural rendering
  ## path; no closing marker is searched in rendered text, so user content can
  ## never change the control-flow tree.
  if depth > engine.maxInheritanceDepth:
    raise newException(ValueError, "Template AST depth exceeded")
  for node in nodes:
    if node.isNil:
      raise newException(ValueError, "Template AST contains a nil node")
    case node.kind
    of templateText:
      result.add(node.value)
    of templateVariable:
      result.add(engine.renderTemplateVariable(node.value, context))
    of templateIf:
      let selected = if truthy(context.getOrDefault(node.value)):
        node.children
      else:
        node.elseChildren
      result.add(engine.renderAstNodes(selected, context, collections,
        projections, depth + 1, hasLocaleFormatter, localeFormatter))
    of templateFor:
      if not collections.hasKey(node.collectionName) and
          not projections.hasKey(node.collectionName):
        raise newException(ValueError,
          "Template collection not found: " & node.collectionName)
      let items = if collections.hasKey(node.collectionName):
        collections[node.collectionName]
      else:
        projections[node.collectionName](context)
      for index, item in items:
        var itemContext = context
        for key, value in item:
          itemContext[node.variableName & "." & key] = value
        ## Loop metadata is request-local context, not parser state. Keeping it
        ## beside the current item makes nested loops naturally shadow the
        ## parent metadata while preserving the caller's scalar context.
        itemContext["loop.index"] = $(index + 1)
        itemContext["loop.index0"] = $index
        itemContext["loop.first"] = $(index == 0)
        itemContext["loop.last"] = $(index == items.high)
        itemContext["loop.length"] = $items.len
        result.add(engine.renderAstNodes(node.children, itemContext,
          collections, projections, depth + 1, hasLocaleFormatter,
          localeFormatter))
      if items.len == 0 and node.elseChildren.len > 0:
        result.add(engine.renderAstNodes(node.elseChildren, context,
          collections, projections, depth + 1, hasLocaleFormatter,
          localeFormatter))
    of templateInclude:
      result.add(engine.renderNamed(node.name, context, collections,
        depth + 1, projections, initTable[string, seq[TemplateNode]](),
        hasLocaleFormatter, localeFormatter))
    of templateHelper:
      if node.name in ["format_decimal", "format_datetime"]:
        if not hasLocaleFormatter:
          raise newException(ValueError,
            "Locale template helper requires a formatter context")
        result.add(escapeHtml(renderLocaleHelper(node.name, node.arguments,
          context, localeFormatter)))
      elif not engine.helpers.hasKey(node.name):
        raise newException(ValueError, "Template helper not found: " & node.name)
      else:
        result.add(escapeHtml(engine.helpers[node.name](node.arguments, context)))
    of templateTag:
      if not engine.tags.hasKey(node.name):
        raise newException(ValueError, "Template tag not found: " & node.name)
      var arguments: seq[string] = @[]
      for argument in node.arguments:
        arguments.add(argument.value)
      result.add(escapeHtml(engine.tags[node.name](arguments, context)))
    of templateBlock:
      result.add(engine.renderAstNodes(node.children, context, collections,
        projections, depth + 1, hasLocaleFormatter, localeFormatter))
    of templateExtends:
      ## Extends is consumed by renderNamed before the materialized root is
      ## rendered. Keeping the node renderable makes parseTemplate useful for
      ## tooling without duplicating inheritance resolution here.
      discard

proc collectAstBlocks(nodes: seq[TemplateNode]): AstBlockMap =
  ## Collect root-level inheritance blocks without returning to source-string
  ## delimiters. Block contents are already parsed and can therefore be
  ## passed between parent/child templates without reparsing user text.
  result = initTable[string, seq[TemplateNode]]()
  for node in nodes:
    if node.kind == templateBlock:
      if result.hasKey(node.name):
        raise newException(ValueError,
          "Duplicate template block: " & node.name)
      result[node.name] = node.children

proc mergeAstBlocks(parent, child: AstBlockMap): AstBlockMap =
  ## Parent blocks are fallbacks; child blocks are authoritative. This order
  ## preserves the expected multi-level inheritance override semantics.
  result = parent
  for name, nodes in child:
    result[name] = nodes

proc cloneAstNode(node: TemplateNode): TemplateNode =
  ## Ref nodes are shared by the parsed AST. Clone before materializing a
  ## parent so replacing child lists cannot mutate a cached tooling AST.
  new(result)
  result[] = node[]

proc materializeAstNodes(nodes: seq[TemplateNode],
                        overrides: AstBlockMap): seq[TemplateNode] =
  ## Apply inheritance recursively over node kinds. Extends is metadata and
  ## never produces output at the root; block nodes become their selected body.
  for node in nodes:
    if node.kind == templateExtends:
      continue
    if node.kind == templateBlock:
      let selected = if overrides.hasKey(node.name):
        overrides[node.name]
      else:
        node.children
      result.add(materializeAstNodes(selected, overrides))
      continue
    let copy = cloneAstNode(node)
    if copy.children.len > 0:
      copy.children = materializeAstNodes(copy.children, overrides)
    if copy.elseChildren.len > 0:
      copy.elseChildren = materializeAstNodes(copy.elseChildren, overrides)
    result.add(copy)

proc renderFragment(engine: TemplateEngine, source: string,
                    context: TemplateContext,
                    collections: Table[string, seq[TemplateContext]],
                    projections: Table[string, TemplateCollectionProjection],
                    depth: int): string =
  ## Includes, control blocks, helpers, and variables are parsed together so
  ## all nesting follows one AST contract. `renderNamed` still owns template
  ## inheritance, while this procedure owns only a materialized fragment.
  if depth > engine.maxInheritanceDepth:
    raise newException(ValueError, "Template recursion depth exceeded")
  let ast = parseTemplate(source)
  result = engine.renderAstNodes(ast.nodes, context, collections,
    projections, depth, false, LocaleFormatPolicy())

proc renderNamed(engine: TemplateEngine, name: string,
                 context: TemplateContext,
                 collections: Table[string, seq[TemplateContext]], depth: int,
                 projections: Table[string, TemplateCollectionProjection],
                 inherited: AstBlockMap,
                 hasLocaleFormatter: bool,
                 localeFormatter: LocaleFormatPolicy): string =
  if depth > engine.maxInheritanceDepth:
    raise newException(ValueError, "Template inheritance depth exceeded")
  let source = engine.templateSource(name)
  let ast = parseTemplate(source)
  var parent = ""
  for node in ast.nodes:
    if node.kind == templateExtends:
      if parent.len > 0:
        raise newException(ValueError,
          "Template may extend only one parent")
      parent = node.name
  let localBlocks = collectAstBlocks(ast.nodes)
  if parent.len > 0:
    return renderNamed(engine, parent, context, collections, depth + 1,
      projections, mergeAstBlocks(localBlocks, inherited),
      hasLocaleFormatter, localeFormatter)
  let materialized = materializeAstNodes(ast.nodes,
    mergeAstBlocks(localBlocks, inherited))
  engine.renderAstNodes(materialized, context, collections, projections, depth,
    hasLocaleFormatter, localeFormatter)

proc render*(engine: TemplateEngine, name: string,
             context: TemplateContext = initTable[string, string]()): string =
  ## Public rendering entry point; all output passes through auto-escaping.
  if engine.isNil:
    raise newException(ValueError, "Template engine is required")
  renderNamed(engine, name, context,
    initTable[string, seq[TemplateContext]](), 0,
    initTable[string, TemplateCollectionProjection](),
    initTable[string, seq[TemplateNode]](), false, LocaleFormatPolicy())

proc render*(engine: TemplateEngine, name: string,
             context: TemplateRenderContext): string =
  ## Collection-aware overload keeps scalar rendering source compatible while
  ## making iteration data explicit at the call site.
  if engine.isNil:
    raise newException(ValueError, "Template engine is required")
  renderNamed(engine, name, context.values, context.collections, 0,
    context.projections, initTable[string, seq[TemplateNode]](),
    context.hasLocaleFormatter, context.localeFormatter)
