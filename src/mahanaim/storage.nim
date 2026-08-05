## Backend-neutral object storage and cache contracts.
##
## HTTP handlers depend on these small interfaces rather than on filesystem,
## Redis, or an S3 SDK. The in-memory adapters provide deterministic local and
## test behavior; the S3-compatible bridge accepts an application-owned
## transport so signing, retries, and provider-specific HTTP remain outside the
## framework core.

import std/[locks, monotimes, options, strutils, tables, times]
import ./redis_resp

type
  StorageError* = object of CatchableError
    ## Invalid keys and adapter contract failures are actionable configuration
    ## errors, not silently converted into cache misses.

  StoredObject* = object
    ## Payload and metadata travel together so object stores can preserve the
    ## content type without coupling callers to an SDK response type.
    key*: string
    data*: string
    contentType*: string
    etag*: string

  ObjectStorage* = ref object of RootObj
    ## Persistence is deliberately opaque to route and upload code.

  InMemoryObjectStorage* = ref object of ObjectStorage
    objects: Table[string, StoredObject]
    lock: Lock

  S3PutObject* = proc(bucket, key, data, contentType: string): string {.gcsafe.}
  S3GetObject* = proc(bucket, key: string): Option[StoredObject] {.gcsafe.}
  S3DeleteObject* = proc(bucket, key: string): bool {.gcsafe.}

  S3ObjectTransport* = ref object
    ## A transport adapter owns HTTP signing, endpoint selection, and retries.
    put*: S3PutObject
    get*: S3GetObject
    delete*: S3DeleteObject

  S3CompatibleObjectStorage* = ref object of ObjectStorage
    bucket*: string
    prefix*: string
    transport*: S3ObjectTransport

  CacheStore* = ref object of RootObj
    ## Cache implementations may be local or distributed, but callers always
    ## observe the same missing/expired value semantics.

  CacheEntry = object
    value: string
    expiresAt: MonoTime
    touchedAt: MonoTime

  InMemoryCacheStore* = ref object of CacheStore
    entries: Table[string, CacheEntry]
    maxEntries: int
    lock: Lock

  RedisCacheStore* = ref object of CacheStore
    ## Redis/Valkey wire lifecycle stays in redis_resp; this adapter only maps
    ## cache semantics to GET/SETEX/SET/DEL and validates response shapes.
    client*: RedisValkeyRespClient
    prefix*: string

proc validateObjectKey(key: string): string =
  ## Object keys are names, not paths. Rejecting traversal and platform
  ## separators keeps local and remote adapters equivalent.
  result = key.strip().replace('\\', '/')
  if result.len == 0 or result.startsWith('/') or result.contains('\0'):
    raise newException(StorageError, "Object key cannot be empty or absolute")
  for segment in result.split('/'):
    if segment.len == 0 or segment == "." or segment == "..":
      raise newException(StorageError, "Object key contains an unsafe segment")

method putObject*(store: ObjectStorage, key, data: string;
                  contentType = "application/octet-stream"): StoredObject
                  {.base, gcsafe.} =
  discard store
  discard key
  discard data
  discard contentType
  raise newException(StorageError, "Object storage put is not implemented")

method getObject*(store: ObjectStorage, key: string): Option[StoredObject]
                  {.base, gcsafe.} =
  discard store
  discard key
  raise newException(StorageError, "Object storage get is not implemented")

method deleteObject*(store: ObjectStorage, key: string): bool {.base, gcsafe.} =
  discard store
  discard key
  raise newException(StorageError, "Object storage delete is not implemented")

proc newInMemoryObjectStorage*(): InMemoryObjectStorage =
  ## A fresh store keeps tests and application instances isolated.
  new(result)
  result.objects = initTable[string, StoredObject]()
  initLock(result.lock)

method putObject*(store: InMemoryObjectStorage, key, data: string;
                  contentType = "application/octet-stream"): StoredObject
                  {.gcsafe.} =
  if store.isNil:
    raise newException(StorageError, "In-memory object storage is required")
  let safeKey = validateObjectKey(key)
  acquire(store.lock)
  defer: release(store.lock)
  result = StoredObject(key: safeKey, data: data,
    contentType: contentType, etag: $data.len & ":" & $safeKey.len)
  store.objects[safeKey] = result

method getObject*(store: InMemoryObjectStorage, key: string): Option[StoredObject]
                  {.gcsafe.} =
  if store.isNil:
    return none(StoredObject)
  let safeKey = validateObjectKey(key)
  acquire(store.lock)
  defer: release(store.lock)
  if store.objects.hasKey(safeKey):
    return some(store.objects[safeKey])
  none(StoredObject)

method deleteObject*(store: InMemoryObjectStorage, key: string): bool {.gcsafe.} =
  if store.isNil:
    return false
  let safeKey = validateObjectKey(key)
  acquire(store.lock)
  defer: release(store.lock)
  if not store.objects.hasKey(safeKey):
    return false
  store.objects.del(safeKey)
  true

proc newS3ObjectTransport*(put: S3PutObject, get: S3GetObject,
                           delete: S3DeleteObject): S3ObjectTransport =
  ## Require all operations together; a half-configured provider would turn a
  ## successful upload into an object that cannot be read or removed.
  if put.isNil or get.isNil or delete.isNil:
    raise newException(StorageError, "S3 object transport requires put/get/delete")
  S3ObjectTransport(put: put, get: get, delete: delete)

proc retryS3Put(transport: S3ObjectTransport, maxAttempts: int,
                bucket, key, data, contentType: string): string =
  ## Retry only the application-owned transport callback. The framework does
  ## not guess which HTTP failures are safe to retry and does not implement
  ## provider-specific signing; the callback remains responsible for those
  ## choices while this boundary guarantees a finite attempt budget.
  var attempt = 0
  while true:
    inc attempt
    try:
      return transport.put(bucket, key, data, contentType)
    except CatchableError:
      if attempt >= maxAttempts:
        raise

proc retryS3Get(transport: S3ObjectTransport, maxAttempts: int,
                bucket, key: string): Option[StoredObject] =
  ## Keep GET retry behavior symmetrical with PUT while preserving the
  ## provider's missing-object `none` result as a successful operation.
  var attempt = 0
  while true:
    inc attempt
    try:
      return transport.get(bucket, key)
    except CatchableError:
      if attempt >= maxAttempts:
        raise

proc retryS3Delete(transport: S3ObjectTransport, maxAttempts: int,
                   bucket, key: string): bool =
  ## A delete callback decides whether a false result means "not found" or a
  ## provider-specific condition; only thrown transport failures are retried.
  var attempt = 0
  while true:
    inc attempt
    try:
      return transport.delete(bucket, key)
    except CatchableError:
      if attempt >= maxAttempts:
        raise

proc newRetryingS3ObjectTransport*(transport: S3ObjectTransport,
                                   maxAttempts = 3): S3ObjectTransport =
  ## Decorate an application-owned S3 transport with a deterministic bounded
  ## retry budget. `maxAttempts` counts the initial call, so 1 disables
  ## retries. Backoff and idempotency classification stay outside this core
  ## wrapper because they depend on the concrete HTTP provider and scheduler.
  if transport.isNil:
    raise newException(StorageError, "S3 transport is required")
  if maxAttempts < 1:
    raise newException(StorageError, "S3 maxAttempts must be positive")
  newS3ObjectTransport(
    proc(bucket, key, data, contentType: string): string =
      retryS3Put(transport, maxAttempts, bucket, key, data, contentType),
    proc(bucket, key: string): Option[StoredObject] =
      retryS3Get(transport, maxAttempts, bucket, key),
    proc(bucket, key: string): bool =
      retryS3Delete(transport, maxAttempts, bucket, key))

proc newS3CompatibleObjectStorage*(bucket: string,
                                   transport: S3ObjectTransport,
                                   prefix = ""): S3CompatibleObjectStorage =
  ## Prefix is normalized once and applied consistently to every operation.
  if bucket.strip().len == 0 or transport.isNil:
    raise newException(StorageError, "S3 bucket and transport are required")
  new(result)
  result.bucket = bucket.strip()
  let normalizedPrefix = prefix.strip().replace('\\', '/').strip(chars = {'/'})
  result.prefix = if normalizedPrefix.len == 0: "" else:
    validateObjectKey(normalizedPrefix)
  result.transport = transport

proc storageKey(store: S3CompatibleObjectStorage, key: string): string =
  let safeKey = validateObjectKey(key)
  if store.prefix.len == 0: safeKey else: store.prefix & "/" & safeKey

method putObject*(store: S3CompatibleObjectStorage, key, data: string;
                  contentType = "application/octet-stream"): StoredObject
                  {.gcsafe.} =
  if store.isNil:
    raise newException(StorageError, "S3 object storage is required")
  let safeKey = validateObjectKey(key)
  let remoteKey = store.storageKey(safeKey)
  let etag = store.transport.put(store.bucket, remoteKey, data, contentType)
  StoredObject(key: safeKey, data: data, contentType: contentType, etag: etag)

method getObject*(store: S3CompatibleObjectStorage, key: string): Option[StoredObject]
                  {.gcsafe.} =
  if store.isNil:
    return none(StoredObject)
  let remoteKey = store.storageKey(key)
  let remote = store.transport.get(store.bucket, remoteKey)
  if remote.isNone:
    return none(StoredObject)
  var remoteObject = remote.get()
  remoteObject.key = key
  some(remoteObject)

method deleteObject*(store: S3CompatibleObjectStorage, key: string): bool
                    {.gcsafe.} =
  if store.isNil:
    return false
  store.transport.delete(store.bucket, store.storageKey(key))

method get*(store: CacheStore, key: string): Option[string] {.base.} =
  discard store
  discard key
  raise newException(StorageError, "Cache store get is not implemented")

method set*(store: CacheStore, key, value: string,
           ttlSeconds = 0) {.base.} =
  discard store
  discard key
  discard value
  discard ttlSeconds
  raise newException(StorageError, "Cache store set is not implemented")

method delete*(store: CacheStore, key: string): bool {.base.} =
  discard store
  discard key
  raise newException(StorageError, "Cache store delete is not implemented")

proc newInMemoryCacheStore*(maxEntries = 10_000): InMemoryCacheStore =
  if maxEntries < 1:
    raise newException(StorageError, "Cache maxEntries must be positive")
  new(result)
  result.entries = initTable[string, CacheEntry]()
  result.maxEntries = maxEntries
  initLock(result.lock)

proc purgeExpiredLocked(store: InMemoryCacheStore, now: MonoTime) =
  var expired: seq[string] = @[]
  for key, entry in store.entries:
    if entry.expiresAt != MonoTime() and now >= entry.expiresAt:
      expired.add(key)
  for key in expired:
    store.entries.del(key)

proc evictOldestLocked(store: InMemoryCacheStore) =
  if store.entries.len < store.maxEntries:
    return
  var oldestKey = ""
  var oldest = getMonoTime()
  for key, entry in store.entries:
    if oldestKey.len == 0 or entry.touchedAt < oldest:
      oldestKey = key
      oldest = entry.touchedAt
  if oldestKey.len > 0:
    store.entries.del(oldestKey)

method get*(store: InMemoryCacheStore, key: string): Option[string] {.gcsafe.} =
  if store.isNil:
    return none(string)
  let safeKey = validateObjectKey(key)
  acquire(store.lock)
  defer: release(store.lock)
  let now = getMonoTime()
  store.purgeExpiredLocked(now)
  if not store.entries.hasKey(safeKey):
    return none(string)
  var entry = store.entries[safeKey]
  entry.touchedAt = now
  store.entries[safeKey] = entry
  some(entry.value)

method set*(store: InMemoryCacheStore, key, value: string,
           ttlSeconds = 0) {.gcsafe.} =
  if store.isNil:
    raise newException(StorageError, "In-memory cache store is required")
  if ttlSeconds < 0:
    raise newException(StorageError, "Cache TTL must not be negative")
  let safeKey = validateObjectKey(key)
  acquire(store.lock)
  defer: release(store.lock)
  let now = getMonoTime()
  store.purgeExpiredLocked(now)
  if not store.entries.hasKey(safeKey):
    store.evictOldestLocked()
  let expiresAt = if ttlSeconds == 0: MonoTime() else:
    now + initDuration(seconds = ttlSeconds)
  store.entries[safeKey] = CacheEntry(value: value, expiresAt: expiresAt,
    touchedAt: now)

method delete*(store: InMemoryCacheStore, key: string): bool {.gcsafe.} =
  if store.isNil:
    return false
  let safeKey = validateObjectKey(key)
  acquire(store.lock)
  defer: release(store.lock)
  if not store.entries.hasKey(safeKey):
    return false
  store.entries.del(safeKey)
  true

proc newRedisCacheStore*(client: RedisValkeyRespClient,
                         prefix = "mahanaim:cache"): RedisCacheStore =
  ## Reuse one configured Redis client so cache and rate-limit operations share
  ## its bounded socket/reconnect behavior without sharing policy state.
  if client.isNil or prefix.strip().len == 0:
    raise newException(StorageError, "Redis cache client and prefix are required")
  new(result)
  result.client = client
  result.prefix = validateObjectKey(prefix)

proc redisCacheKey(store: RedisCacheStore, key: string): string =
  let safeKey = validateObjectKey(key)
  store.prefix & ":" & safeKey

proc redisLine(response: string): string =
  let ending = response.find("\r\n")
  if ending < 0:
    raise newException(StorageError, "Incomplete Redis cache response")
  response[0 ..< ending]

proc redisBulkValue(response: string): Option[string] =
  ## Parse only a Redis bulk string and reject trailing bytes, preventing a
  ## malformed response from becoming a valid cache value.
  if response.len < 4 or response[0] != '$':
    raise newException(StorageError, "Redis cache GET response is not bulk data")
  let line = redisLine(response)
  let length = try: parseInt(line[1 .. ^1])
                except ValueError:
                  raise newException(StorageError, "Invalid Redis cache bulk length")
  if length == -1:
    if response.len != line.len + 2:
      raise newException(StorageError, "Invalid Redis nil response")
    return none(string)
  if length < 0 or response.len != line.len + 2 + length + 2 or
      response[line.len + 2 + length .. ^1] != "\r\n":
    raise newException(StorageError, "Invalid Redis cache bulk payload")
  some(response[line.len + 2 ..< line.len + 2 + length])

proc redisInteger(response: string, operation: string): int =
  let line = redisLine(response)
  if line.len < 2 or line[0] != ':':
    raise newException(StorageError, "Redis cache " & operation & " response is not integer")
  try: parseInt(line[1 .. ^1])
  except ValueError:
    raise newException(StorageError, "Invalid Redis cache " & operation & " response")

proc ensureRedisOk(response, operation: string) =
  let line = redisLine(response)
  if line != "+OK":
    raise newException(StorageError,
      "Redis cache " & operation & " failed: " & line)

method get*(store: RedisCacheStore, key: string): Option[string] =
  if store.isNil:
    return none(string)
  let command = encodeRedisCommand(["GET", store.redisCacheKey(key)])
  redisBulkValue(store.client.executeCommand(command))

method set*(store: RedisCacheStore, key, value: string,
           ttlSeconds = 0) =
  if store.isNil:
    raise newException(StorageError, "Redis cache store is required")
  if ttlSeconds < 0:
    raise newException(StorageError, "Cache TTL must not be negative")
  let remoteKey = store.redisCacheKey(key)
  let command = if ttlSeconds == 0:
    encodeRedisCommand(["SET", remoteKey, value])
  else:
    encodeRedisCommand(["SETEX", remoteKey, $ttlSeconds, value])
  ensureRedisOk(store.client.executeCommand(command), "set")

method delete*(store: RedisCacheStore, key: string): bool =
  if store.isNil:
    return false
  redisInteger(store.client.executeCommand(
    encodeRedisCommand(["DEL", store.redisCacheKey(key)])), "delete") > 0
