## Transport-neutral W3C trace context primitives.
##
## The framework only owns validation and propagation. Span timing/export stays
## in an adapter or OpenTelemetry integration, so request handlers do not
## depend on a tracing vendor.

import std/[options, strutils]

type
  TraceContext* = object
    ## W3C trace identifiers are kept as lowercase hexadecimal strings.
    traceId*: string
    spanId*: string
    traceFlags*: string

proc isLowerHex(value: string): bool =
  for character in value:
    if character notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc validTraceContext*(context: TraceContext): bool =
  ## Reject all-zero identifiers and malformed flags before reflection.
  context.traceId.len == 32 and context.spanId.len == 16 and
    context.traceFlags.len == 2 and isLowerHex(context.traceId) and
    isLowerHex(context.spanId) and isLowerHex(context.traceFlags) and
    context.traceId != repeat('0', 32) and context.spanId != repeat('0', 16)

proc parseTraceParent*(value: string): Option[TraceContext] =
  ## Parse `version-trace-id-parent-id-flags`; unsupported versions are kept
  ## out of the core until their propagation semantics are explicitly known.
  let parts = value.strip().split('-')
  if parts.len != 4 or parts[0] != "00":
    return none(TraceContext)
  let context = TraceContext(traceId: parts[1], spanId: parts[2],
    traceFlags: parts[3])
  if not context.validTraceContext():
    return none(TraceContext)
  some(context)

proc traceParentHeader*(context: TraceContext): string =
  ## Serialize only a validated context; invalid state is a programming error.
  if not context.validTraceContext():
    raise newException(ValueError, "Invalid trace context")
  "00-" & context.traceId & "-" & context.spanId & "-" & context.traceFlags

proc traceContextForSequence*(sequence: int): TraceContext =
  ## Deterministic IDs keep tests reproducible while remaining unique per app.
  if sequence <= 0:
    raise newException(ValueError, "Trace sequence must be positive")
  let traceId = toHex(sequence, 32).toLowerAscii()
  let spanId = toHex(sequence, 16).toLowerAscii()
  TraceContext(traceId: traceId, spanId: spanId, traceFlags: "01")
