import std/[httpcore, strutils, tables, unittest]
import mahanaim/http_adapter

suite "HTTP adapter headers":
  test "preserves every media type in a browser Accept header":
    var headers = newHttpHeaders()
    headers["Accept"] =
      "text/html,application/xhtml+xml,application/xml;q=0.9," &
      "image/avif,image/webp,image/apng,*/*;q=0.8," &
      "application/signed-exchange;v=b3;q=0.7"

    let copied = copyHeaders(headers)

    check copied["accept"].contains("text/html")
    check copied["accept"].contains("application/signed-exchange")
