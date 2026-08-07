# Authorization

**Audience:** developers protecting routes, Admin resources, and individual objects.
**Verified with:** `nimble test`

`AuthorizationPolicy` is explicit and route guards are ordinary middleware. Set
roles/groups from verified identity data, then apply the narrowest guard to a
route group or individual endpoint. Object policy must evaluate the loaded
resource and `request.auth`, not a client-supplied owner identifier.

Design with least privilege: define a reader role for safe views, an editor role
for mutation, and a separate administrator role for operational actions. Deny
by default. Apply the same rule to API, HTML, background job, and Admin entry
points so one representation cannot bypass another.

Authorization failure should be a generic 403 (or an intentional 404 where
resource enumeration must be hidden), with a redacted audit record. Test an
anonymous request, authenticated wrong-role request, and authenticated
wrong-object request for every sensitive route.
