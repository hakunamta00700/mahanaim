## Request-scoped locale negotiation.
##
## This module owns HTTP language preference parsing and leaves translations to
## templates or application services. That split keeps the core request
## contract stable while allowing any renderer to consume Request.locale.

import std/[asyncdispatch, algorithm, math, strutils, tables, times]
import timezones
import ./core

type
  LocalePolicy* = object
    supportedLocales*: seq[string]
    defaultLocale*: string
    timezoneOffsetMinutes*: int

  LocaleFormatPolicy* = object
    ## Formatting is separate from negotiation: applications can choose either
    ## a deterministic fixed offset or an IANA-backed timezone at this seam.
    ## The timezone database stays inside localization, so templates and API
    ## handlers consume the same DateTime formatting contract without knowing
    ## the provider's representation.
    locale*: string
    timezoneOffsetMinutes*: int
    timezoneName*: string
    timezone: Timezone

proc normalizedLocale(value: string): string =
  value.strip().toLowerAscii().replace('_', '-')

proc newLocalePolicy*(supportedLocales: openArray[string],
                      defaultLocale: string,
                      timezoneOffsetMinutes = 0): LocalePolicy =
  ## Validate the fallback once so every request can negotiate without a
  ## per-request configuration error.
  if supportedLocales.len == 0 or defaultLocale.strip().len == 0:
    raise newException(ValueError,
      "Locale policy requires supported locales and a default locale")
  if timezoneOffsetMinutes < -24 * 60 or timezoneOffsetMinutes > 24 * 60:
    raise newException(ValueError, "Locale timezone offset is out of range")
  result.defaultLocale = defaultLocale.strip()
  result.timezoneOffsetMinutes = timezoneOffsetMinutes
  for locale in supportedLocales:
    if locale.strip().len == 0:
      raise newException(ValueError, "Supported locale cannot be empty")
    var duplicate = false
    for existing in result.supportedLocales:
      if normalizedLocale(existing) == normalizedLocale(locale):
        duplicate = true
        break
    if not duplicate:
      result.supportedLocales.add(locale.strip())
  var defaultSupported = false
  for locale in result.supportedLocales:
    if normalizedLocale(locale) == normalizedLocale(result.defaultLocale):
      defaultSupported = true
      break
  if not defaultSupported:
    raise newException(ValueError, "Default locale must be supported")

proc supportedValue(policy: LocalePolicy, requested: string): string =
  let normalized = normalizedLocale(requested)
  for locale in policy.supportedLocales:
    if normalizedLocale(locale) == normalized:
      return locale
  ## A regional preference may fall back to its base language (`ko-KR` -> `ko`).
  let separator = normalized.find('-')
  if separator > 0:
    let base = normalized[0 ..< separator]
    for locale in policy.supportedLocales:
      if normalizedLocale(locale) == base:
        return locale
  ""

proc negotiateLocale*(policy: LocalePolicy, acceptLanguage: string): string =
  ## Parse only the language and q-value grammar needed by HTTP clients. The
  ## highest quality supported language wins; malformed q-values are ignored.
  var candidates: seq[tuple[value: string, quality: float, order: int]] = @[]
  let languageRanges = acceptLanguage.split(',')
  for order in 0 ..< languageRanges.len:
    let raw = languageRanges[order]
    let parts = raw.split(';')
    let value = parts[0].strip()
    if value.len == 0:
      continue
    var quality = 1.0
    for parameter in parts[1 ..< parts.len]:
      let pair = parameter.split('=', 1)
      if pair.len == 2 and pair[0].strip().toLowerAscii() == "q":
        try: quality = parseFloat(pair[1].strip())
        except ValueError: quality = 0.0
    if quality > 0:
      candidates.add((value, quality, order))
  candidates.sort(proc(left, right: auto): int =
    if left.quality == right.quality: cmp(left.order, right.order)
    else: cmp(right.quality, left.quality))
  for candidate in candidates:
    if candidate.value == "*":
      return policy.defaultLocale
    let selected = policy.supportedValue(candidate.value)
    if selected.len > 0:
      return selected
  policy.defaultLocale

proc localeMiddleware*(policy: LocalePolicy): Middleware =
  ## Middleware copies the request snapshot before injecting locale, preserving
  ## the value-object pipeline and avoiding hidden mutable global locale state.
  let configured = policy
  result = proc(request: Request, next: Handler): Future[Response]
      {.async, gcsafe.} =
    var localized = request
    localized.locale = configured.negotiateLocale(
      request.headers.getOrDefault("accept-language"))
    localized.timezoneOffsetMinutes = configured.timezoneOffsetMinutes
    return await next(localized)

proc newLocaleFormatPolicy*(locale = "en", timezoneOffsetMinutes = 0):
    LocaleFormatPolicy =
  ## A fixed offset is deterministic and serializable. An application that
  ## needs DST/IANA rules can implement the same formatting seam upstream.
  if locale.strip().len == 0:
    raise newException(ValueError, "Locale formatter locale is required")
  if timezoneOffsetMinutes < -24 * 60 or timezoneOffsetMinutes > 24 * 60:
    raise newException(ValueError, "Locale timezone offset is out of range")
  LocaleFormatPolicy(locale: normalizedLocale(locale),
    timezoneOffsetMinutes: timezoneOffsetMinutes, timezoneName: "",
    timezone: nil)

proc newIanaLocaleFormatPolicy*(locale, timezoneName: string):
    LocaleFormatPolicy =
  ## Resolve the IANA name once during application configuration. This avoids
  ## parsing timezone data on every request and makes invalid deployment
  ## configuration fail before the server starts.
  if locale.strip().len == 0:
    raise newException(ValueError, "Locale formatter locale is required")
  if timezoneName.strip().len == 0:
    raise newException(ValueError, "IANA timezone name is required")
  let zone = tz(timezoneName.strip())
  LocaleFormatPolicy(locale: normalizedLocale(locale),
    timezoneOffsetMinutes: 0, timezoneName: timezoneName.strip(), timezone: zone)

proc padNumber(value, width: int): string =
  let raw = $value
  if raw.len >= width: raw else: repeat('0', width - raw.len) & raw

proc localeUsesCommaDecimal(locale: string): bool =
  let normalized = normalizedLocale(locale)
  normalized.startsWith("de") or normalized.startsWith("fr") or
    normalized.startsWith("es") or normalized.startsWith("it")

proc groupInteger(value: string, separator: char): string =
  ## Group only the integer portion, retaining a leading sign if present.
  var sign = ""
  var digits = value
  if digits.startsWith("-") or digits.startsWith("+"):
    sign = digits[0 .. 0]
    digits = digits[1 .. ^1]
  var firstGroup = digits.len mod 3
  if firstGroup == 0: firstGroup = 3
  result = sign & digits[0 ..< firstGroup]
  var cursor = firstGroup
  while cursor < digits.len:
    result.add(separator)
    result.add(digits[cursor ..< min(cursor + 3, digits.len)])
    cursor += 3

proc formatDecimal*(policy: LocaleFormatPolicy, value: float,
                    fractionDigits = 2): string =
  ## Format a finite decimal with locale separators and bounded precision.
  if fractionDigits < 0 or fractionDigits > 12:
    raise newException(ValueError, "Locale fraction digits must be 0..12")
  if value.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "Locale formatter accepts finite numbers only")
  let raw = formatFloat(value, ffDecimal, fractionDigits)
  let decimalSeparator = if localeUsesCommaDecimal(policy.locale): ',' else: '.'
  let groupingSeparator = if decimalSeparator == ',': '.' else: ','
  let point = raw.find('.')
  if point < 0:
    return groupInteger(raw, groupingSeparator)
  let integerPart = groupInteger(raw[0 ..< point], groupingSeparator)
  integerPart & decimalSeparator & raw[point + 1 .. ^1]

proc formatDateTime*(policy: LocaleFormatPolicy, value: DateTime): string =
  ## Convert the instant through the selected provider first, then apply a
  ## stable locale pattern. `DateTime.inZone` uses the instant's UTC value and
  ## therefore applies historical/DST transitions instead of adding a stale
  ## fixed offset.
  let localized = if policy.timezone.isNil:
    value + initDuration(minutes = policy.timezoneOffsetMinutes)
  else:
    value.inZone(policy.timezone)
  let normalized = normalizedLocale(policy.locale)
  if normalized.startsWith("en"):
    let hour12 = if localized.hour mod 12 == 0: 12 else: localized.hour mod 12
    let meridiem = if localized.hour < 12: "AM" else: "PM"
    return $localized.month.int & "/" & $localized.monthday & "/" &
      $localized.year & " " & $hour12 & ":" & padNumber(localized.minute, 2) &
      " " & meridiem
  $localized.year & "-" & padNumber(localized.month.int, 2) & "-" &
    padNumber(localized.monthday, 2) & " " & padNumber(localized.hour, 2) &
    ":" & padNumber(localized.minute, 2)

proc timezoneOffsetMinutes*(policy: LocaleFormatPolicy, value: DateTime): int =
  ## Expose the resolved offset for audit logs and tests without leaking the
  ## concrete `Timezone` object to callers. The result can change across DST.
  if policy.timezone.isNil:
    return policy.timezoneOffsetMinutes
  ## Nim's `utcOffset` is expressed as seconds west of UTC, while this
  ## framework's public fixed-offset convention is minutes east of UTC.
  -(policy.timezone.zonedTimeFromTime(value.toTime).utcOffset div 60)
