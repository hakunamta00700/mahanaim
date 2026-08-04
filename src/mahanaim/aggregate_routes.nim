## HTTP adapter for repository-owned aggregate queries.
##
## Query construction remains an application concern: the route receives an
## explicit factory rather than turning arbitrary request text into SQL. This
## keeps authorization and query policy visible at the route registration
## boundary while reusing the repository's safe compiler and result mapper.

import std/[asyncdispatch, httpcore, json, tables]
import ./application
import ./core
import ./database
import ./database_repository
import ./resources
import ./validation

type
  AggregateQueryFactory* = proc(request: Request): QuerySet {.gcsafe.}

proc aggregateDocument(rows: seq[ResourceRow]): JsonNode =
  ## Convert repository rows to one stable JSON array at the HTTP boundary.
  result = newJArray()
  for row in rows:
    var objectNode = newJObject()
    for name, value in row:
      objectNode[name] = value
    result.add(objectNode)

proc aggregateResponse*(repository: DatabaseRepository,
                        query: QuerySet): Response {.gcsafe.} =
  ## Keep aggregate execution independent from route registration for service
  ## code and tests that need the same response contract without an app.
  jsonResponse(aggregateDocument(repository.aggregate(query)))

proc invalidAggregateResponse(request: Request,
                              error: ref CatchableError): Response =
  ## Do not expose driver details, but keep a structured query-scoped error for
  ## callers and the common validation/problem response contract.
  request.problemResponseFor(Http400, "Invalid aggregate query",
    "The aggregate query could not be executed", @[
      ValidationIssue(field: "query", location: "query", code: "invalid_aggregate",
        message: error.msg)])

proc registerAggregateRoute*(app: Application,
                             repository: DatabaseRepository,
                             prefix, name: string,
                             factory: AggregateQueryFactory) =
  ## Register one explicit aggregate endpoint; callers can register multiple
  ## reports with different authorization and query factories.
  if app.isNil or repository.isNil or prefix.len == 0 or name.len == 0 or
      factory.isNil:
    raise newException(ValueError,
      "Aggregate route requires app, repository, prefix, name, and factory")
  app.get(prefix, name,
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      try:
        return aggregateResponse(repository, factory(request))
      except CatchableError as error:
        return invalidAggregateResponse(request, error))
