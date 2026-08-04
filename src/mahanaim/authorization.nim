## Composable authorization policy.
##
## Authentication establishes who a request represents; this module decides
## what that subject may do. Keeping role/group lookup and object policy behind
## one contract lets routes, admin resources, and future plugins share the same
## guard without importing a session or token implementation.

import std/[asyncdispatch, httpcore, strutils, tables]
import ./core

type
  ObjectAuthorization* = proc(request: Request, resource, action,
                              objectId: string): bool {.gcsafe.}

  AuthorizationPolicy* = ref object
    ## Registry state is application-owned; it is never process-global.
    rolePermissions: Table[string, seq[string]]
    subjectRoles: Table[string, seq[string]]
    groupRoles: Table[string, seq[string]]
    subjectGroups: Table[string, seq[string]]
    objectPolicy*: ObjectAuthorization

proc newAuthorizationPolicy*(): AuthorizationPolicy =
  ## Empty policies fail closed until permissions are explicitly granted.
  new(result)
  result.rolePermissions = initTable[string, seq[string]]()
  result.subjectRoles = initTable[string, seq[string]]()
  result.groupRoles = initTable[string, seq[string]]()
  result.subjectGroups = initTable[string, seq[string]]()

proc permissionKey(resource, action: string): string =
  ## Normalize one permission identity so every guard compares the same value.
  if resource.strip().len == 0 or action.strip().len == 0:
    raise newException(ValueError, "Permission resource and action are required")
  resource.strip() & ":" & action.strip()

proc addUnique(values: var seq[string], value: string) =
  if value notin values:
    values.add(value)

proc grantPermission*(policy: AuthorizationPolicy, role, resource, action: string) =
  ## Roles own capabilities; subjects and groups only reference those roles.
  if policy.isNil or role.strip().len == 0:
    raise newException(ValueError, "Authorization policy and role are required")
  var permissions = policy.rolePermissions.getOrDefault(role.strip(), @[])
  permissions.addUnique(permissionKey(resource, action))
  policy.rolePermissions[role.strip()] = permissions

proc assignRole*(policy: AuthorizationPolicy, subject, role: string) =
  ## Direct role assignment is useful for service identities and small apps.
  if policy.isNil or subject.strip().len == 0 or role.strip().len == 0:
    raise newException(ValueError, "Subject and role are required")
  var roles = policy.subjectRoles.getOrDefault(subject.strip(), @[])
  roles.addUnique(role.strip())
  policy.subjectRoles[subject.strip()] = roles

proc addGroupRole*(policy: AuthorizationPolicy, group, role: string) =
  ## Groups map to roles, avoiding duplicated permission lists for teams.
  if policy.isNil or group.strip().len == 0 or role.strip().len == 0:
    raise newException(ValueError, "Group and role are required")
  var roles = policy.groupRoles.getOrDefault(group.strip(), @[])
  roles.addUnique(role.strip())
  policy.groupRoles[group.strip()] = roles

proc addSubjectToGroup*(policy: AuthorizationPolicy, subject, group: string) =
  ## Membership is separate from role definition so an identity store can
  ## later populate these maps without changing route guards.
  if policy.isNil or subject.strip().len == 0 or group.strip().len == 0:
    raise newException(ValueError, "Subject and group are required")
  var groups = policy.subjectGroups.getOrDefault(subject.strip(), @[])
  groups.addUnique(group.strip())
  policy.subjectGroups[subject.strip()] = groups

proc roleAllows(policy: AuthorizationPolicy, role, requested: string): bool =
  for permission in policy.rolePermissions.getOrDefault(role, @[]):
    if permission == requested or permission == "*:*" or
       permission == requested.split(':')[0] & ":*":
      return true
  false

proc allows*(policy: AuthorizationPolicy, request: Request,
            resource, action: string, objectId = ""): bool {.gcsafe.} =
  ## Evaluate coarse role permission first, then the optional object policy.
  ## This ordering prevents an object callback from accidentally granting a
  ## capability that no role was allowed to request.
  if policy.isNil or not request.auth.authenticated:
    return false
  let requested = permissionKey(resource, action)
  let subject = request.auth.subject
  for role in policy.subjectRoles.getOrDefault(subject, @[]):
    if policy.roleAllows(role, requested):
      if policy.objectPolicy.isNil or
         policy.objectPolicy(request, resource, action, objectId):
        return true
  for group in policy.subjectGroups.getOrDefault(subject, @[]):
    for role in policy.groupRoles.getOrDefault(group, @[]):
      if policy.roleAllows(role, requested):
        if policy.objectPolicy.isNil or
           policy.objectPolicy(request, resource, action, objectId):
          return true
  false

proc requirePermission*(policy: AuthorizationPolicy,
                        resource, action: string): Middleware =
  ## Route guards are ordinary middleware, so groups and route declarations can
  ## compose without special handling in Router or Application.
  if policy.isNil:
    raise newException(ValueError, "Authorization policy is required")
  discard permissionKey(resource, action)
  result = proc(request: Request, next: Handler): Future[Response] {.async, gcsafe.} =
    let objectId = request.pathParams.getOrDefault("id")
    if not policy.allows(request, resource, action, objectId):
      return textResponse("Forbidden", Http403)
    return await next(request)
