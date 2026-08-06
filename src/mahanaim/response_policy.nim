## Content negotiation for response representations.
##
## Handlers can construct HTML, JSON, and text responses independently. This
## policy selects among those already-rendered variants, keeping HTTP Accept
## parsing out of business logic and making 406 behavior consistent.

import std/[algorithm, httpcore, options, strutils, tables]
import nimcrypto
import ./core

type AcceptedMedia = object
  value: string
  quality: float
  order: int

proc acceptedTypes(request: Request): seq[AcceptedMedia] =
  ## Parse quality values so clients can express representation preference.
  let header = request.header("accept")
  if header.isNone:
    return @[]
  let items = header.get().split(',')
  for order in 0 ..< items.len:
    let item = items[order]
    let pieces = item.split(';')
    let mediaType = pieces[0].strip().toLowerAscii()
    if mediaType.len == 0:
      continue
    var quality = 1.0
    if pieces.len > 1:
      for index in 1 ..< pieces.len:
        let assignment = pieces[index].split('=', maxsplit = 1)
        if assignment.len == 2 and assignment[0].strip().toLowerAscii() == "q":
          try:
            quality = parseFloat(assignment[1].strip())
          except ValueError:
            quality = 0.0
    result.add(AcceptedMedia(value: mediaType,
      quality: max(0.0, min(1.0, quality)), order: order))
  result.sort(proc(left, right: AcceptedMedia): int =
    if left.quality > right.quality: -1
    elif left.quality < right.quality: 1
    else: cmp(left.order, right.order))

proc mediaType(response: Response): string =
  ## Compare only the media type portion, not charset parameters.
  let contentType = response.header("content-type")
  if contentType.isNone:
    return ""
  contentType.get().split(';', maxsplit = 1)[0].strip().toLowerAscii()

proc mediaTypeMatches(accepted, offered: string): bool =
  if accepted == "*/*" or accepted == offered:
    return true
  let offeredSlash = offered.find('/')
  accepted.endsWith("/*") and offeredSlash > 0 and
    accepted[0 ..< accepted.len - 1] == offered[0 ..< offeredSlash] & "/"

proc withAcceptVary(response: Response): Response =
  ## A negotiated response must tell intermediary caches that its bytes depend
  ## on the Accept header. Keep an existing Vary value (for example
  ## `HX-Request`) and add Accept exactly once so helper composition remains
  ## safe for both network adapters and in-process callers.
  result = response
  let existing = result.headers.getOrDefault("vary", "")
  if existing.len == 0:
    result.headers["vary"] = "Accept"
  else:
    var hasAccept = false
    for value in existing.toLowerAscii().split(','):
      if value.strip() == "accept":
        hasAccept = true
        break
    if not hasAccept:
      result.headers["vary"] = existing & ", Accept"

proc bufferedResponseEtag*(response: Response): string =
  ## Derive a strong entity tag only for buffered representations. Streaming,
  ## SSE, and WebSocket responses have transport-level framing or lifecycle
  ## state, so hashing their current buffer would create a misleading cache
  ## contract. An explicitly supplied ETag remains application-owned.
  if response.representation in {rrStream, rrServerSentEvents, rrWebSocket}:
    return ""
  let existing = response.header("etag")
  if existing.isSome:
    return existing.get()
  "\"" & ($sha256.digest(response.body)).toLowerAscii() & "\""

proc weakComparableEtag(value: string): string =
  ## If-None-Match uses weak comparison: W/"x" and "x" identify the same
  ## representation for cache validation. Keep parsing local to this policy so
  ## adapters do not implement subtly different header semantics.
  result = value.strip()
  if result.toUpperAscii().startsWith("W/"):
    result = result[2 .. ^1].strip()

proc matchesIfNoneMatch(header, etag: string): bool =
  for candidate in header.split(','):
    let normalized = candidate.strip()
    if normalized == "*" or
       weakComparableEtag(normalized) == weakComparableEtag(etag):
      return true

proc conditionalResponse*(request: Request, response: Response): Response =
  ## Attach an ETag and convert a matching GET/HEAD request into 304. The
  ## policy runs after content negotiation so a representation's bytes are
  ## hashed once and the same result is observed by in-process and wire tests.
  result = response
  let etag = bufferedResponseEtag(result)
  if etag.len == 0:
    return
  result.headers["etag"] = etag
  let candidate = request.header("if-none-match")
  if candidate.isNone or not matchesIfNoneMatch(candidate.get(), etag):
    return
  result.status = if request.httpMethod.toUpperAscii() in ["GET", "HEAD"]:
    Http304
  else:
    Http412
  result.body = ""
  result.filePath = ""
  result.variants = @[]

proc negotiateResponse*(request: Request,
                        variants: openArray[Response]): Response =
  ## Select the first server-preferred variant accepted by the client.
  if variants.len == 0:
    return withAcceptVary(textResponse("Not Acceptable", Http406))
  let accepted = request.acceptedTypes()
  if accepted.len == 0:
    return withAcceptVary(variants[0])
  for requested in accepted:
    for variant in variants:
      let offered = mediaType(variant)
      if requested.quality > 0 and mediaTypeMatches(requested.value, offered):
        return withAcceptVary(variant)
  withAcceptVary(textResponse("Not Acceptable", Http406))

proc negotiateResponse*(request: Request, response: Response): Response =
  ## Validate a single final representation at an adapter boundary. This is
  ## intentionally separate from the variant selector so handlers that only
  ## have one representation still get deterministic 406 wire behavior.
  if response.variants.len > 0:
    ## Candidate selection belongs here rather than in each adapter, keeping
    ## HTTP and Prologue behavior identical for buffered and streaming bodies.
    return negotiateResponse(request, response.variants)
  let accepted = request.acceptedTypes()
  if accepted.len == 0:
    return response
  let offered = response.mediaType()
  ## Empty responses such as 204 and redirects carry protocol metadata rather
  ## than a representation. An Accept header cannot reject bytes that do not
  ## exist, and must not replace the original status with 406.
  if offered.len == 0 and response.body.len == 0:
    return response
  for requested in accepted:
    if requested.quality > 0 and mediaTypeMatches(requested.value, offered):
      return withAcceptVary(response)
  withAcceptVary(textResponse("Not Acceptable", Http406))

proc isHtmxRequest*(request: Request): bool =
  ## HTMX is detected from its explicit request header, not from User-Agent or
  ## an arbitrary query flag, so the representation choice remains auditable.
  let value = request.header("hx-request")
  value.isSome and value.get().strip().toLowerAscii() in ["true", "1"]

proc htmlJsonResponse*(request: Request, fullHtml, partialHtml,
                       jsonBody: string, status = Http200): Response =
  ## A single route can serve a browser document, an HTMX fragment, or JSON.
  ## HTML stays the default server preference; the partial is selected only
  ## for an explicit HTMX request, while Accept negotiation still controls
  ## JSON clients and produces 406 for unsupported media types.
  let htmlBody = if request.isHtmxRequest and partialHtml.len > 0:
    partialHtml
  else:
    fullHtml
  var selected = negotiateResponse(request, [
    htmlResponse(htmlBody, status), jsonResponse(jsonBody, status)])
  var headers = selected.headers
  headers["vary"] = "Accept, HX-Request"
  selected.headers = headers
  selected
