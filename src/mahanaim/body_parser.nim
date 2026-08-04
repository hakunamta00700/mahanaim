## Framework-neutral request body parsing.
##
## Adapters only need to populate `Request.body` and `Content-Type`. Keeping
## decoding here prevents Prologue or stdlib-specific parsing rules from
## leaking into validation and handler code.

import std/[options, strutils, tables, uri]
import ./core

type
  BodyEncoding* = enum
    beNone
    beJson
    beFormUrlEncoded
    beMultipart

  BodyPart* = object
    ## A multipart part retains file metadata while exposing regular fields.
    name*: string
    filename*: string
    contentType*: string
    content*: string

  BodyParseResult* = object
    ## Structured results let validation report a body-scoped error without
    ## throwing parser exceptions through the request dispatcher.
    encoding*: BodyEncoding
    valid*: bool
    fields*: Table[string, string]
    parts*: seq[BodyPart]
    errorCode*: string
    errorMessage*: string

proc headerValue(request: Request, name: string): string =
  let value = request.header(name)
  if value.isSome: value.get() else: ""

proc mediaType(value: string): string =
  value.split(';', maxsplit = 1)[0].strip().toLowerAscii()

proc parameter(value, name: string): Option[string] =
  ## Read a simple quoted or unquoted Content-Type parameter.
  for rawPart in value.split(';'):
    let pieces = rawPart.split('=', maxsplit = 1)
    if pieces.len == 2 and pieces[0].strip().toLowerAscii() == name:
      var resultValue = pieces[1].strip()
      if resultValue.len >= 2 and resultValue[0] == '"' and
          resultValue[^1] == '"':
        resultValue = resultValue[1 ..< resultValue.high]
      return some(resultValue)
  none(string)

proc headerLine(lines: seq[string], name: string): string =
  for line in lines:
    let separator = line.find(':')
    if separator > 0 and line[0 ..< separator].strip().toLowerAscii() == name:
      return line[separator + 1 .. ^1].strip()
  ""

proc dispositionParameter(value, name: string): string =
  let found = value.parameter(name)
  if found.isSome: found.get() else: ""

proc parseMultipart(request: Request, boundary: string): BodyParseResult =
  result.encoding = beMultipart
  result.valid = true
  result.fields = initTable[string, string]()
  result.parts = @[]
  let delimiter = "--" & boundary
  let segments = request.body.split(delimiter)
  if segments.len < 2:
    result.valid = false
    result.errorCode = "invalid_multipart"
    result.errorMessage = "Multipart body does not contain its boundary"
    return

  for rawSegment in segments[1 .. ^1]:
    var segment = rawSegment
    if segment.startsWith("--"):
      break
    if segment.startsWith("\r\n"):
      segment = segment[2 .. ^1]
    elif segment.startsWith("\n"):
      segment = segment[1 .. ^1]
    if segment.len == 0:
      continue
    if segment.endsWith("\r\n"):
      segment.setLen(segment.len - 2)
    elif segment.endsWith("\n"):
      segment.setLen(segment.len - 1)
    let separator = segment.find("\r\n\r\n")
    let separatorWidth = 4
    if separator < 0:
      result.valid = false
      result.errorCode = "invalid_multipart"
      result.errorMessage = "Multipart part is missing its header separator"
      continue
    let headers = segment[0 ..< separator].split("\r\n")
    let contentDisposition = headerLine(headers, "content-disposition")
    let name = contentDisposition.dispositionParameter("name")
    if name.len == 0:
      result.valid = false
      result.errorCode = "invalid_multipart"
      result.errorMessage = "Multipart part is missing a field name"
      continue
    let contentType = headerLine(headers, "content-type")
    let filename = contentDisposition.dispositionParameter("filename")
    let content = segment[separator + separatorWidth .. ^1]
    result.parts.add(BodyPart(name: name, filename: filename,
      contentType: contentType, content: content))
    if filename.len == 0:
      result.fields[name] = content

proc parseRequestBody*(request: Request): BodyParseResult =
  ## Parse supported encodings without interpreting arbitrary raw payloads.
  result.fields = initTable[string, string]()
  result.parts = @[]
  let contentType = headerValue(request, "content-type")
  let kind = mediaType(contentType)
  if kind == "application/x-www-form-urlencoded":
    result.encoding = beFormUrlEncoded
    result.valid = true
    for key, value in decodeQuery(request.body):
      result.fields[key] = value
    return
  if kind == "multipart/form-data":
    let boundary = contentType.parameter("boundary")
    if boundary.isNone or boundary.get().len == 0:
      result.encoding = beMultipart
      result.valid = false
      result.errorCode = "missing_multipart_boundary"
      result.errorMessage = "Multipart content type requires a boundary"
      return
    return parseMultipart(request, boundary.get())
  if kind == "application/json" or kind.endsWith("+json") or
      (kind.len == 0 and (request.body.strip().startsWith("{") or
       request.body.strip().startsWith("["))):
    result.encoding = beJson
    result.valid = true
    return
  result.encoding = beNone
  result.valid = true
