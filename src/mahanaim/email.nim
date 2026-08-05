## Framework-neutral email message and transport contracts.
##
## The core owns message validation and deterministic RFC 5322 rendering. It
## deliberately does not own SMTP sockets, credentials, retries, or provider
## policy; those concerns belong to an application-owned `EmailTransport`.

import std/[strutils]

type
  EmailMessage* = object
    ## Mailbox fields contain plain addresses. Display-name encoding and
    ## provider-specific headers can be added by a transport adapter without
    ## changing the framework's delivery contract.
    sender*: string
    recipients*: seq[string]
    cc*: seq[string]
    bcc*: seq[string]
    subject*: string
    contentType*: string
    body*: string

  EmailTransport* = ref object of RootObj
    ## A transport is intentionally small: the framework gives it a validated
    ## message, while the adapter decides how and where delivery occurs.

  EmailWireCallback* = proc(wire: string) {.gcsafe.}

  CallbackEmailTransport* = ref object of EmailTransport
    ## This bridge is the explicit seam for SMTP, API mail providers, or a
    ## durable outbox. The callback receives normalized wire data only after
    ## the framework has completed its local validation.
    callback*: EmailWireCallback

  InMemoryEmailTransport* = ref object of EmailTransport
    ## This adapter is deterministic and useful for tests and local previews;
    ## it must not be mistaken for durable or production delivery.
    messages*: seq[EmailMessage]

proc validateHeaderValue(value, fieldName: string) =
  ## Header injection is rejected before any transport sees the message. ASCII
  ## is intentional here: non-ASCII subjects need RFC 2047 encoded-words, and
  ## silently emitting invalid raw header bytes would be worse than a clear
  ## contract error. UTF-8 message bodies remain fully supported.
  if value.len == 0 or value.contains({'\r', '\n'}):
    raise newException(ValueError, fieldName & " must be printable ASCII")
  for character in value:
    if ord(character) < 32 or ord(character) > 126:
      raise newException(ValueError, fieldName & " must be printable ASCII")

proc validateMailbox(value, fieldName: string) =
  ## This is a deliberately conservative mailbox check, not a full RFC 5322
  ## parser. Provider adapters can expose richer address objects later, while
  ## this common boundary prevents malformed addresses and header injection.
  let mailbox = value.strip()
  if mailbox != value or mailbox.count('@') != 1:
    raise newException(ValueError, fieldName & " must be a single mailbox")
  let parts = mailbox.split('@')
  if parts[0].len == 0 or parts[1].len == 0 or
      parts[0].startsWith('.') or parts[0].endsWith('.') or
      parts[1].startsWith('.') or parts[1].endsWith('.'):
    raise newException(ValueError, fieldName & " contains an invalid mailbox")
  for character in mailbox:
    if ord(character) < 33 or ord(character) > 126 or
        character in {'<', '>', ',', ';'}:
      raise newException(ValueError, fieldName & " contains an invalid mailbox")

proc normalizeBody(value: string): string =
  ## RFC 5322 uses CRLF regardless of the host operating system. Normalizing
  ## once at the renderer boundary keeps transports and tests consistent on
  ## Windows, Linux, and application-provided in-memory adapters.
  result = value.replace("\r\n", "\n").replace('\r', '\n')
  result = result.replace("\n", "\r\n")
  if not result.endsWith("\r\n"):
    result.add("\r\n")

proc renderEmail*(message: EmailMessage): string =
  ## Render one simple-part message. Multipart MIME and encoded display names
  ## remain transport/application extensions so the core keeps one clear
  ## responsibility: validating and serializing the portable base contract.
  validateMailbox(message.sender, "Email sender")
  if message.recipients.len == 0 and message.cc.len == 0 and message.bcc.len == 0:
    raise newException(ValueError, "Email requires at least one recipient")
  for index, recipient in message.recipients:
    validateMailbox(recipient, "Email recipient " & $index)
  for index, recipient in message.cc:
    validateMailbox(recipient, "Email cc recipient " & $index)
  for index, recipient in message.bcc:
    validateMailbox(recipient, "Email bcc recipient " & $index)
  validateHeaderValue(message.subject, "Email subject")
  validateHeaderValue(message.contentType, "Email content type")
  result = "From: " & message.sender & "\r\n"
  if message.recipients.len > 0:
    result.add("To: " & message.recipients.join(", ") & "\r\n")
  if message.cc.len > 0:
    result.add("Cc: " & message.cc.join(", ") & "\r\n")
  result.add("Subject: " & message.subject & "\r\n")
  result.add("MIME-Version: 1.0\r\n")
  result.add("Content-Type: " & message.contentType & "\r\n\r\n")
  result.add(normalizeBody(message.body))

method send*(transport: EmailTransport, message: EmailMessage) {.base, gcsafe.} =
  ## Keep the base method explicit so an incomplete provider fails loudly
  ## instead of silently reporting a successful delivery.
  discard transport
  discard message
  raise newException(ValueError, "Email transport does not implement send")

proc newCallbackEmailTransport*(callback: EmailWireCallback):
    CallbackEmailTransport =
  ## Require the application-owned delivery function at construction time so
  ## a configured transport cannot silently drop a message at runtime.
  if callback.isNil:
    raise newException(ValueError, "Email wire callback is required")
  new(result)
  result.callback = callback

method send*(transport: CallbackEmailTransport, message: EmailMessage)
    {.gcsafe.} =
  ## Rendering happens before callback invocation, keeping external adapters
  ## from receiving partially validated headers or recipient lists.
  if transport.isNil or transport.callback.isNil:
    raise newException(ValueError, "Email wire callback is required")
  transport.callback(renderEmail(message))

proc newInMemoryEmailTransport*(): InMemoryEmailTransport =
  ## A new adapter owns its own message list, preventing test/application
  ## instances from sharing delivery state accidentally.
  new(result)
  result.messages = @[]

method send*(transport: InMemoryEmailTransport, message: EmailMessage)
    {.gcsafe.} =
  ## Validate through the same renderer that production adapters can reuse,
  ## then retain the structured message for deterministic assertions.
  discard renderEmail(message)
  transport.messages.add(message)
