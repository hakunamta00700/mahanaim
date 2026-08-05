## Definition of Done document contract.
##
## The checklist is a release input, not only prose. This test keeps its
## required sections and verification commands machine-checkable so a future
## edit cannot silently remove the evidence boundary from the framework.

import std/[os, sequtils, strutils, unittest]
import mahanaim

suite "definition of done contracts":
  test "repository checklist contains the required evidence sections":
    let issues = validateDefinitionOfDone(getCurrentDir() / "docs" /
      "definition-of-done.md")
    check issues.len == 0

  test "malformed checklist reports every missing contract":
    let path = getTempDir() / "mahanaim-definition-of-done-invalid.md"
    writeFile(path, """
## 기능 단위 체크리스트
- [X] malformed marker
## 검증 게이트
nimble test
## 상태 표기 규칙
""")
    defer:
      if fileExists(path):
        removeFile(path)
    let issues = validateDefinitionOfDone(path)
    check issues.len >= 2
    check issues.anyIt(it.contains("verification command is missing"))
    check issues.anyIt(it.contains("checkbox marker is invalid"))
