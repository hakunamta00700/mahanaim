## Account authentication route composition.
##
## Password hashing, login throttling, and signed sessions each have their own
## contracts. This module composes them into a small login/logout boundary while
## keeping account persistence behind an adapter, so a database-backed store
## can replace the reference store without changing route behavior.

import std/[asyncdispatch, httpcore, json, locks, options, strutils, tables]
import ./application
import ./core
import ./login_throttling
import ./password_hashing
import ./security

type
  PasswordResetDelivery* = proc(subject, token: string) {.gcsafe.}

  AccountCredential* = object
    ## Only the password hash crosses this boundary; plaintext is request-local
    ## and is never stored in the account record or returned in a response.
    subject*: string
    identifier*: string
    passwordHash*: string
    enabled*: bool

  AccountCredentialStore* = ref object of RootObj
    ## Persistence is deliberately separate from route and security policy.

  InMemoryAccountCredentialStore* = ref object of AccountCredentialStore
    ## Reference storage is deterministic for tests and local development;
    ## production applications should provide a transactional implementation.
    accounts: Table[string, AccountCredential]
    subjects: Table[string, string]
    lock: Lock

  AccountAuthentication* = ref object
    ## One immutable route composition owns all policy dependencies, which
    ## makes registration explicit and prevents routes from using mismatched
    ## hashers, session secrets, or throttle stores.
    store*: AccountCredentialStore
    hasher*: Pbkdf2PasswordHasher
    sessionPolicy*: SessionPolicy
    throttle*: LoginThrottleStore
    loginPath*: string
    logoutPath*: string
    changePasswordPath*: string
    resetRequestPath*: string
    resetConfirmPath*: string
    resetSecret*: string
    resetTtlSeconds*: int64
    resetTokenStore*: PasswordResetTokenStore
    resetDelivery*: PasswordResetDelivery

method findByIdentifier*(store: AccountCredentialStore,
                         identifier: string): Option[AccountCredential] {.base, gcsafe.} =
  ## A backend must return none for unknown identifiers without exposing a
  ## database-specific error or account enumeration detail to route callers.
  discard store
  discard identifier
  raise newException(ValueError, "Account credential lookup is not implemented")

method findBySubject*(store: AccountCredentialStore,
                      subject: string): Option[AccountCredential] {.base, gcsafe.} =
  discard store
  discard subject
  raise newException(ValueError, "Account subject lookup is not implemented")

method updatePasswordHash*(store: AccountCredentialStore,
                           subject, passwordHash: string) {.base, gcsafe.} =
  ## Rehash persistence is a separate operation so it can run in the caller's
  ## transaction and never silently commit unrelated account changes.
  discard store
  discard subject
  discard passwordHash
  raise newException(ValueError, "Account password update is not implemented")

proc newInMemoryAccountCredentialStore*(): InMemoryAccountCredentialStore =
  ## Initialize isolated maps and a lock; tests must never share account state
  ## through a process-global singleton.
  new(result)
  result.accounts = initTable[string, AccountCredential]()
  result.subjects = initTable[string, string]()
  initLock(result.lock)

proc normalizeIdentifier(identifier: string): string =
  ## Stable normalization avoids duplicate accounts that differ only by outer
  ## whitespace while leaving case policy to the application domain.
  identifier.strip()

proc addAccount*(store: InMemoryAccountCredentialStore,
                 account: AccountCredential) =
  ## Account creation is intentionally explicit; login routes never create
  ## accounts as a side effect of an authentication attempt.
  let identifier = normalizeIdentifier(account.identifier)
  if store.isNil or identifier.len == 0 or account.subject.strip().len == 0 or
      account.passwordHash.len == 0:
    raise newException(ValueError, "Account requires subject, identifier, and password hash")
  acquire(store.lock)
  defer: release(store.lock)
  if store.accounts.hasKey(identifier) or store.subjects.hasKey(account.subject):
    raise newException(ValueError, "Duplicate account identifier or subject")
  var normalized = account
  normalized.identifier = identifier
  store.accounts[identifier] = normalized
  store.subjects[account.subject] = identifier

method findByIdentifier*(store: InMemoryAccountCredentialStore,
                         identifier: string): Option[AccountCredential] {.gcsafe.} =
  if store.isNil:
    return none(AccountCredential)
  acquire(store.lock)
  defer: release(store.lock)
  let key = normalizeIdentifier(identifier)
  if store.accounts.hasKey(key):
    return some(store.accounts[key])
  none(AccountCredential)

method findBySubject*(store: InMemoryAccountCredentialStore,
                      subject: string): Option[AccountCredential] {.gcsafe.} =
  if store.isNil:
    return none(AccountCredential)
  acquire(store.lock)
  defer: release(store.lock)
  if not store.subjects.hasKey(subject):
    return none(AccountCredential)
  let identifier = store.subjects[subject]
  some(store.accounts[identifier])

method updatePasswordHash*(store: InMemoryAccountCredentialStore,
                           subject, passwordHash: string) {.gcsafe.} =
  if store.isNil or subject.strip().len == 0 or passwordHash.len == 0:
    raise newException(ValueError, "Account password update requires subject and hash")
  acquire(store.lock)
  defer: release(store.lock)
  if not store.subjects.hasKey(subject):
    raise newException(ValueError, "Unknown account subject")
  let identifier = store.subjects[subject]
  var account = store.accounts[identifier]
  account.passwordHash = passwordHash
  store.accounts[identifier] = account

proc newAccountAuthentication*(store: AccountCredentialStore,
                               hasher: Pbkdf2PasswordHasher,
                               sessionPolicy: SessionPolicy,
                               throttle: LoginThrottleStore = nil,
                               loginPath = "/login",
                               logoutPath = "/logout",
                               changePasswordPath = "/account/password",
                               resetRequestPath = "/password-reset",
                               resetConfirmPath = "/password-reset/confirm",
                               resetSecret = "",
                               resetTtlSeconds: int64 = 0,
                               resetTokenStore: PasswordResetTokenStore = nil,
                               resetDelivery: PasswordResetDelivery = nil):
                               AccountAuthentication =
  ## Validate all dependencies at composition time so an application cannot
  ## boot with a public login route and a missing session or throttle policy.
  if store.isNil or hasher.isNil or not sessionPolicy.enabled or
      sessionPolicy.secret.len < 32 or sessionPolicy.cookieName.strip().len == 0:
    raise newException(ValueError,
      "Account authentication requires store, hasher, and enabled session policy")
  if loginPath.len == 0 or loginPath[0] != '/' or logoutPath.len == 0 or
      logoutPath[0] != '/' or changePasswordPath.len == 0 or
      changePasswordPath[0] != '/' or resetRequestPath.len == 0 or
      resetRequestPath[0] != '/' or resetConfirmPath.len == 0 or
      resetConfirmPath[0] != '/':
    raise newException(ValueError, "Account authentication paths must be absolute")
  let resetConfigured = resetSecret.len > 0 or resetTtlSeconds > 0 or
    not resetTokenStore.isNil or not resetDelivery.isNil
  if resetConfigured and (resetSecret.len < 32 or resetTtlSeconds <= 0 or
      resetTokenStore.isNil or resetDelivery.isNil):
    raise newException(ValueError,
      "Password reset requires secret, TTL, token store, and delivery")
  new(result)
  result.store = store
  result.hasher = hasher
  result.sessionPolicy = sessionPolicy
  result.throttle = if throttle.isNil: newInMemoryLoginThrottle() else: throttle
  result.loginPath = loginPath
  result.logoutPath = logoutPath
  result.changePasswordPath = changePasswordPath
  result.resetRequestPath = resetRequestPath
  result.resetConfirmPath = resetConfirmPath
  result.resetSecret = resetSecret
  result.resetTtlSeconds = resetTtlSeconds
  result.resetTokenStore = resetTokenStore
  result.resetDelivery = resetDelivery

proc credentialsFromBody(body: string): Option[(string, string)] =
  ## Keep request parsing local to the route adapter; persistence never sees a
  ## malformed document or an unknown extra field.
  try:
    let document = parseJson(body)
    if document.kind != JObject or not document.hasKey("identifier") or
        not document.hasKey("password") or
        document["identifier"].kind != JString or
        document["password"].kind != JString:
      return none((string, string))
    let identifier = document["identifier"].getStr().strip()
    let password = document["password"].getStr()
    if identifier.len == 0 or password.len == 0:
      return none((string, string))
    some((identifier, password))
  except CatchableError:
    none((string, string))

proc passwordChangeFromBody(body: string): Option[(string, string)] =
  ## Password changes use distinct field names so an identifier cannot be
  ## accidentally interpreted as a new password by a caller.
  try:
    let document = parseJson(body)
    if document.kind != JObject or not document.hasKey("currentPassword") or
        not document.hasKey("newPassword") or
        document["currentPassword"].kind != JString or
        document["newPassword"].kind != JString:
      return none((string, string))
    let currentPassword = document["currentPassword"].getStr()
    let newPassword = document["newPassword"].getStr()
    if currentPassword.len == 0 or newPassword.len == 0:
      return none((string, string))
    some((currentPassword, newPassword))
  except CatchableError:
    none((string, string))

proc resetRequestFromBody(body: string): Option[string] =
  ## Reset requests accept only an identifier; the response never reveals
  ## whether that identifier maps to an account.
  try:
    let document = parseJson(body)
    if document.kind != JObject or not document.hasKey("identifier") or
        document["identifier"].kind != JString:
      return none(string)
    let identifier = document["identifier"].getStr().strip()
    if identifier.len == 0: none(string) else: some(identifier)
  except CatchableError:
    none(string)

proc resetConfirmationFromBody(body: string): Option[(string, string, string)] =
  ## The subject is carried inside the signed token as well; requiring it here
  ## lets the store lookup remain backend-neutral without trusting it alone.
  try:
    let document = parseJson(body)
    if document.kind != JObject or not document.hasKey("subject") or
        not document.hasKey("token") or not document.hasKey("newPassword") or
        document["subject"].kind != JString or
        document["token"].kind != JString or
        document["newPassword"].kind != JString:
      return none((string, string, string))
    let subject = document["subject"].getStr().strip()
    let token = document["token"].getStr()
    let newPassword = document["newPassword"].getStr()
    if subject.len == 0 or token.len == 0 or newPassword.len == 0:
      return none((string, string, string))
    some((subject, token, newPassword))
  except CatchableError:
    none((string, string, string))

proc failedLoginResponse(): Response =
  ## One response shape prevents callers from distinguishing unknown, disabled,
  ## or incorrectly credentialed accounts.
  textResponse("Authentication failed", Http401)

proc registerAccountAuthenticationRoutes*(app: Application,
                                          authentication: AccountAuthentication) =
  ## Register only the two core session lifecycle operations. Password reset
  ## and account provisioning remain separate flows with their own CSRF and
  ## transactional policies rather than becoming hidden route side effects.
  if app.isNil or authentication.isNil:
    raise newException(ValueError, "Application and account authentication are required")
  let current = authentication
  app.post(current.loginPath, "auth.login",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      let credentials = credentialsFromBody(request.body)
      if credentials.isNone:
        return textResponse("Invalid credentials payload", Http400)
      let identifier = credentials.get()[0]
      let password = credentials.get()[1]
      let throttleKey = "login:" & identifier
      let decision = current.throttle.checkAttempt(throttleKey)
      if not decision.allowed:
        var response = textResponse("Too many authentication attempts", Http429)
        response.headers["retry-after"] = $decision.retryAfterSeconds
        return response
      let account = current.store.findByIdentifier(identifier)
      if account.isNone or not account.get().enabled:
        current.throttle.recordFailure(throttleKey)
        return failedLoginResponse()
      let verification = current.hasher.verifyAndRehash(password,
        account.get().passwordHash)
      if not verification.valid:
        current.throttle.recordFailure(throttleKey)
        return failedLoginResponse()
      if verification.rehashed:
        current.store.updatePasswordHash(account.get().subject,
          verification.encoded)
      current.throttle.recordSuccess(throttleKey)
      var response = jsonResponse(%*{
        "authenticated": true,
        "subject": account.get().subject})
      response.setSessionCookie(current.sessionPolicy, account.get().subject)
      return response)
  app.post(current.logoutPath, "auth.logout",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      var response = newResponse(Http204)
      response.clearSessionCookie(current.sessionPolicy)
      return response)
  app.post(current.changePasswordPath, "auth.change-password",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      ## The middleware normally binds the session before this handler. The
      ## explicit fallback keeps the route contract safe when embedded without
      ## the standard security middleware chain.
      var authenticatedRequest = request
      if not authenticatedRequest.auth.authenticated and
          not authenticatedRequest.bindSession(current.sessionPolicy):
        return textResponse("Authentication required", Http401)
      let credentials = passwordChangeFromBody(request.body)
      if credentials.isNone:
        return textResponse("Invalid password payload", Http400)
      let account = current.store.findBySubject(
        authenticatedRequest.auth.subject)
      if account.isNone or not account.get().enabled:
        return textResponse("Authentication required", Http401)
      let changed = current.hasher.changePassword(credentials.get()[0],
        credentials.get()[1], account.get().passwordHash)
      if not changed.valid:
        return textResponse("Current password is invalid", Http400)
      current.store.updatePasswordHash(account.get().subject, changed.encoded)
      return newResponse(Http204))
  if not current.resetTokenStore.isNil:
    app.post(current.resetRequestPath, "auth.password-reset-request",
      proc(request: Request): Future[Response] {.async, gcsafe.} =
        ## Always return the same accepted response. Delivery failures remain
        ## adapter errors and are not converted into account enumeration.
        let identifier = resetRequestFromBody(request.body)
        if identifier.isSome:
          let account = current.store.findByIdentifier(identifier.get())
          if account.isSome and account.get().enabled:
            let token = issuePasswordResetToken(current.resetSecret,
              account.get().subject, current.resetTtlSeconds)
            current.resetDelivery(account.get().subject, token)
        return newResponse(Http202))
    app.post(current.resetConfirmPath, "auth.password-reset-confirm",
      proc(request: Request): Future[Response] {.async, gcsafe.} =
        let confirmation = resetConfirmationFromBody(request.body)
        if confirmation.isNone:
          return textResponse("Invalid password reset payload", Http400)
        let subject = confirmation.get()[0]
        let account = current.store.findBySubject(subject)
        if account.isNone or not account.get().enabled or
            not current.resetTokenStore.consumePasswordResetToken(
              current.resetSecret, confirmation.get()[1], subject):
          return textResponse("Invalid or expired password reset", Http400)
        let hash = current.hasher.hashPassword(confirmation.get()[2])
        current.store.updatePasswordHash(subject, hash)
        return newResponse(Http204))
