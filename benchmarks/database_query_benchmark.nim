## Deterministic ORM/query compiler benchmark.
##
## This measures the framework-owned AST-to-CompiledQuery boundary rather than
## a database server. It is intentionally self-validating: a benchmark that
## produces malformed SQL or loses bound parameters must fail even when its
## elapsed time looks reasonable.

import std/[monotimes, strutils, times]
import mahanaim/database

const
  QueryCount = 10_000

proc benchmarkQuery(index: int): QuerySet =
  ## Build the same representative query shape with changing bound data. The
  ## value remains a parameter, so the workload also protects the no-interpolation
  ## boundary while exercising projection, filtering, ordering, and pagination.
  newQuerySet("orders").
    selectFields(["id", "customer_id", "total"]).
    whereFilter(QueryFilter(field: "status", operator: filterEqual,
      value: SqlValue(kind: sqlText, text: if index mod 2 == 0:
        "paid" else: "pending"))).
    orderByField("created_at", descending = true).
    paginate(Pagination(page: (index mod 10) + 1, pageSize: 50,
      maxPageSize: 100))

proc main() =
  var compiled = 0
  var parameterCount = 0
  let started = getMonoTime()
  for index in 0 ..< QueryCount:
    let query = benchmarkQuery(index)
    let sqlite = query.compile(dialectSqlite)
    let postgres = query.compile(dialectPostgres)
    doAssert sqlite.sql.contains("SELECT")
    doAssert postgres.sql.contains("$1")
    doAssert sqlite.parameters.len == 1
    doAssert postgres.parameters.len == 1
    doAssert not sqlite.sql.contains("paid")
    doAssert not postgres.sql.contains("pending")
    inc compiled, 2
    inc parameterCount, sqlite.parameters.len + postgres.parameters.len
  let elapsed = getMonoTime() - started

  ## Keep output comparable across machines while leaving latency interpretation
  ## to maintainers and CI artifacts instead of imposing a fragile threshold.
  doAssert compiled == QueryCount * 2
  doAssert parameterCount == QueryCount * 2
  echo "queries=" & $QueryCount &
    " compiled=" & $compiled &
    " bound_parameters=" & $parameterCount &
    " elapsed_ms=" & $elapsed.inMilliseconds

when isMainModule:
  main()
