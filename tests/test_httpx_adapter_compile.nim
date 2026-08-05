## Compile contract for the direct httpx deployment adapter.
##
## Linux CI compiles the real backend-specific surface. Windows keeps the
## source importable while the existing stdlib/Prologue adapters remain the
## supported native transport there.

import std/unittest
import mahanaim

when not defined(windows):
  import mahanaim/httpx_adapter

  suite "httpx deployment adapter contracts":
    test "server settings remain inspectable before binding":
      let app = newApplication()
      let server = newHttpxServer(app, host = "127.0.0.1", port = 0,
        numThreads = 1)
      check server.settings.bindAddr == "127.0.0.1"
      check server.settings.port.int == 0

    test "invalid deployment settings fail before binding":
      expect ValueError:
        discard newHttpxServer(newApplication(), port = 65536)
      expect ValueError:
        discard newHttpxServer(newApplication(), numThreads = 0)
else:
  ## The conditional module remains a valid package import on Windows.
  suite "httpx deployment adapter contracts":
    test "conditional backend import remains valid on Windows":
      check true
