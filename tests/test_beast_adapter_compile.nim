## Compile-only contract for the non-Windows Beast/httpx adapter path.
##
## The executable test suite runs on Windows as well, where Prologue selects
## stdlib sockets. This target keeps the Beast-specific overloads type-checked
## on Linux CI without pretending a compile check is a live socket test.

when defined(windows):
  static: doAssert true
else:
  import mahanaim/[core, application, prologue_server, websocket_adapter]

  static:
    ## Referencing the exported contracts forces the compiler to instantiate
    ## the Beast/httpx overloads and their socket ownership declarations.
    doAssert compiles(newApplication())
    doAssert compiles(newWebSocketSession())
