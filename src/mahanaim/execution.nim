## Handler execution policy.
##
## Nim's async event loop must never be blocked by accidental synchronous I/O.
## The first contract records sync handlers explicitly and allows deployments
## to reject them until an executor/thread-pool adapter is configured.

type
  ExecutionPolicy* = object
    ## `allowSynchronousHandlers` is permissive for local development; a
    ## production application can set it false and fail during dispatch.
    allowSynchronousHandlers*: bool
    warnOnSynchronousHandlers*: bool

proc defaultExecutionPolicy*(): ExecutionPolicy =
  ## Keep the existing developer experience while making the decision explicit.
  ExecutionPolicy(allowSynchronousHandlers: true,
    warnOnSynchronousHandlers: true)
