## Content negotiation for response representations.
##
## Handlers can construct HTML, JSON, and text responses independently. This
## policy selects among those already-rendered variants, keeping HTTP Accept
## parsing out of business logic and making 406 behavior consistent.

import std/[httpcore, options, strutils]
import ./core

proc acceptedTypes(request: Request): seq[string] =
  ## Parse media types and ignore optional parameters such as q values.
  let header = request.header("accept")
  if header.isNone:
    return @[]
  for item in header.get().split(','):
    let mediaType = item.split(';', maxsplit = 1)[0].strip().toLowerAscii()
    if mediaType.len > 0:
      result.add(mediaType)

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
  for variant in variants:
    let offered = mediaType(variant)
    for requested in accepted:
      if mediaTypeMatches(requested, offered):
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
    if mediaTypeMatches(requested, offered):
      return response
  textResponse("Not Acceptable", Http406)
