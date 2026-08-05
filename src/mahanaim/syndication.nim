## Deterministic XML renderers for server-side discovery documents.
##
## Sitemap and RSS generation is kept independent from HTTP routing and data
## storage. Applications can build entries from any repository, then expose
## the returned XML through `xmlResponse` or an adapter-specific response.

import std/[strutils]

type
  SiteMapEntry* = object
    ## A sitemap entry intentionally uses wire-ready strings so date policy is
    ## owned by the application rather than guessed by this renderer.
    location*: string
    lastModified*: string
    changeFrequency*: string
    priority*: float

  RssItem* = object
    title*: string
    link*: string
    guid*: string
    description*: string
    publishedAt*: string

  RssFeed* = object
    title*: string
    link*: string
    description*: string
    items*: seq[RssItem]

  AtomEntry* = object
    ## Atom requires an immutable entry identity and a last-updated value.
    ## Link and content remain wire-ready strings so applications retain
    ## ownership of routing, publication dates, and content serialization.
    title*: string
    id*: string
    link*: string
    updatedAt*: string
    summary*: string
    content*: string

  AtomFeed* = object
    ## The feed identity is separate from its navigational link: an endpoint
    ## may move while its Atom `id` remains stable for clients and crawlers.
    title*: string
    link*: string
    id*: string
    updatedAt*: string
    entries*: seq[AtomEntry]

const xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"

proc escapeXml(value: string): string =
  ## Escape text-node content explicitly; no HTML renderer is required for XML
  ## and ampersands must be handled before the other entities.
  result = value.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")
  result = result.replace("'", "&apos;")

proc validateHttpUrl(value, fieldName: string) =
  ## Both formats require absolute HTTP(S) URLs so generated documents never
  ## publish a relative link that crawlers interpret differently by context.
  let normalized = value.strip()
  if normalized.len == 0 or normalized != value or
      (not normalized.startsWith("http://") and
       not normalized.startsWith("https://")) or
      normalized.contains("\r") or normalized.contains("\n") or
      normalized.contains("\t") or normalized.contains(" "):
    raise newException(ValueError, fieldName & " must be an absolute HTTP URL")

proc renderSitemap*(entries: openArray[SiteMapEntry]): string =
  ## Preserve caller order for deterministic output; callers can sort by their
  ## own publication policy before rendering without coupling this helper to a
  ## database or a timestamp clock.
  result = xmlHeader &
    "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">"
  for entry in entries:
    validateHttpUrl(entry.location, "Sitemap location")
    if entry.changeFrequency.len > 0 and entry.changeFrequency notin [
        "always", "hourly", "daily", "weekly", "monthly", "yearly", "never"]:
      raise newException(ValueError, "Invalid sitemap change frequency")
    if entry.priority < 0.0 or entry.priority > 1.0:
      raise newException(ValueError, "Sitemap priority must be between 0 and 1")
    result.add("<url><loc>" & escapeXml(entry.location) & "</loc>")
    if entry.lastModified.len > 0:
      result.add("<lastmod>" & escapeXml(entry.lastModified) & "</lastmod>")
    if entry.changeFrequency.len > 0:
      result.add("<changefreq>" & escapeXml(entry.changeFrequency) &
        "</changefreq>")
    if entry.priority > 0.0:
      result.add("<priority>" & formatFloat(entry.priority, ffDecimal, 1) &
        "</priority>")
    result.add("</url>")
  result.add("</urlset>")

proc renderRss*(feed: RssFeed): string =
  ## Render RSS 2.0 with stable item order and optional item metadata. The
  ## renderer validates every link before emitting partial XML so callers do
  ## not accidentally publish a malformed feed after a late bad item.
  if feed.title.strip().len == 0 or feed.description.strip().len == 0:
    raise newException(ValueError, "RSS title and description are required")
  validateHttpUrl(feed.link, "RSS feed link")
  result = xmlHeader & "<rss version=\"2.0\"><channel>"
  result.add("<title>" & escapeXml(feed.title) & "</title>")
  result.add("<link>" & escapeXml(feed.link) & "</link>")
  result.add("<description>" & escapeXml(feed.description) &
    "</description>")
  for item in feed.items:
    if item.title.strip().len == 0 or item.description.strip().len == 0:
      raise newException(ValueError, "RSS item title and description are required")
    validateHttpUrl(item.link, "RSS item link")
    result.add("<item><title>" & escapeXml(item.title) & "</title>")
    result.add("<link>" & escapeXml(item.link) & "</link>")
    if item.guid.len > 0:
      result.add("<guid>" & escapeXml(item.guid) & "</guid>")
    result.add("<description>" & escapeXml(item.description) &
      "</description>")
    if item.publishedAt.len > 0:
      result.add("<pubDate>" & escapeXml(item.publishedAt) & "</pubDate>")
    result.add("</item>")
  result.add("</channel></rss>")

proc requireAtomText(value, fieldName: string) =
  ## Atom identifiers and timestamps are deliberately validated as opaque
  ## non-empty text. Date parsing belongs to the application because forcing
  ## one date library here would couple this framework-neutral renderer to a
  ## publication policy it cannot safely infer.
  if value.strip().len == 0 or value.contains({'\r', '\n', '\t'}):
    raise newException(ValueError, fieldName & " is required")

proc renderAtom*(feed: AtomFeed): string =
  ## Render Atom 1.0 without knowing how entries were loaded or how the HTTP
  ## response is served. Validate the complete feed before emitting entries so
  ## a late malformed item cannot produce a partially trusted document.
  requireAtomText(feed.title, "Atom feed title")
  requireAtomText(feed.id, "Atom feed id")
  requireAtomText(feed.updatedAt, "Atom feed updatedAt")
  validateHttpUrl(feed.link, "Atom feed link")
  result = xmlHeader & "<feed xmlns=\"http://www.w3.org/2005/Atom\">"
  result.add("<title>" & escapeXml(feed.title) & "</title>")
  result.add("<id>" & escapeXml(feed.id) & "</id>")
  result.add("<updated>" & escapeXml(feed.updatedAt) & "</updated>")
  result.add("<link href=\"" & escapeXml(feed.link) & "\"/>")
  for entry in feed.entries:
    requireAtomText(entry.title, "Atom entry title")
    requireAtomText(entry.id, "Atom entry id")
    requireAtomText(entry.updatedAt, "Atom entry updatedAt")
    if entry.link.len == 0 and entry.summary.len == 0 and entry.content.len == 0:
      raise newException(ValueError,
        "Atom entry link, summary, or content is required")
    if entry.link.len > 0:
      validateHttpUrl(entry.link, "Atom entry link")
    result.add("<entry><title>" & escapeXml(entry.title) & "</title>")
    result.add("<id>" & escapeXml(entry.id) & "</id>")
    result.add("<updated>" & escapeXml(entry.updatedAt) & "</updated>")
    if entry.link.len > 0:
      result.add("<link href=\"" & escapeXml(entry.link) & "\"/>")
    if entry.summary.len > 0:
      result.add("<summary>" & escapeXml(entry.summary) & "</summary>")
    if entry.content.len > 0:
      result.add("<content>" & escapeXml(entry.content) & "</content>")
    result.add("</entry>")
  result.add("</feed>")
