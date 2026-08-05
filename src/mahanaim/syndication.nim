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
