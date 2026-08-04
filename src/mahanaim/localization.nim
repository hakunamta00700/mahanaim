## Request-scoped locale negotiation.
##
## This module owns HTTP language preference parsing and leaves translations to
## templates or application services. That split keeps the core request
## contract stable while allowing any renderer to consume Request.locale.

import std/[asyncdispatch, algorithm, strutils, tables]
import ./core

type
  LocalePolicy* = object
    supportedLocales*: seq[string]
    defaultLocale*: string

proc normalizedLocale(value: string): string =
  value.strip().toLowerAscii().replace('_', '-')

proc newLocalePolicy*(supportedLocales: openArray[string],
                      defaultLocale: string): LocalePolicy =
  ## Validate the fallback once so every request can negotiate without a
  ## per-request configuration error.
  if supportedLocales.len == 0 or defaultLocale.strip().len == 0:
    raise newException(ValueError,
      "Locale policy requires supported locales and a default locale")
  result.defaultLocale = defaultLocale.strip()
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
    return await next(localized)
