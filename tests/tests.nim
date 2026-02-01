## Gold master tests for Nimmy.
## Runs all .nimmy scripts and compares output to .txt files.
import
  std/[os, strutils],
  ../src/nimmy
proc runTests() =
  let scriptsDir = currentSourcePath().parentDir() / "scripts"
  doAssert dirExists(scriptsDir), "Scripts directory not found: " & scriptsDir
  var passed, failed = 0
  for kind, path in walkDir(scriptsDir):
    if kind != pcFile or not path.endsWith(".nimmy"):
      continue
    let testName = path.extractFilename().changeFileExt("")
    let expectedPath = path.changeFileExt(".txt")
    if not fileExists(expectedPath):
      echo "SKIP " & testName & " (no .txt file)"
      continue
    let expected = readFile(expectedPath).replace("\r\n", "\n").strip()
    var actual = ""
    var errorMsg = ""
    try:
      let nvm = newNimmyVM()
      actual = nvm.runFile(path).replace("\r\n", "\n").strip()
    except NimmyError as e:
      errorMsg = e.msg
    except CatchableError as e:
      errorMsg = "Unexpected: " & e.msg
    if errorMsg.len > 0:
      echo "FAIL " & testName
      echo "  Error: " & errorMsg
      failed += 1
    elif actual == expected:
      echo "PASS " & testName
      passed += 1
    else:
      echo "FAIL " & testName
      echo "  Expected: " & expected.splitLines()[0] & "..."
      echo "  Actual:   " & actual.splitLines()[0] & "..."
      failed += 1
  echo ""
  echo "Results: " & $passed & " passed, " & $failed & " failed"
  doAssert failed == 0, "Some tests failed"
echo "Running Nimmy tests..."
runTests()
