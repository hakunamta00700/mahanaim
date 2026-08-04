## Content negotiation for response representations.
##
## Handlers can construct HTML, JSON, and text responses independently. This
## policy selects among those already-rendered variants, keeping HTTP Accept
## parsing out of business logic and making 406 behavior consistent.

import std/[algorithm, httpcore, options, strutils]
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

proc negotiateResponse*(request: Request,
                        variants: openArray[Response]): Response =
  ## Select the first server-preferred variant accepted by the client.
  if variants.len == 0:
    return textResponse("Not Acceptable", Http406)
  let accepted = request.acceptedTypes()
  if accepted.len == 0:
    return variants[0]
  for requested in accepted:
    for variant in variants:
      let offered = mediaType(variant)
      if requested.quality > 0 and mediaTypeMatches(requested.value, offered):
        return variant
  textResponse("Not Acceptable", Http406)

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
  for requested in accepted:
    if requested.quality > 0 and mediaTypeMatches(requested.value, offered):
      return response
  textResponse("Not Acceptable", Http406)
