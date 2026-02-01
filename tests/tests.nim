## Gold master tests for Nimmy.
## Runs all .nimmy scripts and compares output to .txt files.
## - scripts/  : Normal tests (expected to succeed)
## - errors/   : Runtime error tests (expected to fail)
## - syntax/   : Syntax error tests (expected to fail during parsing)
import
  std/[os, strutils],
  ../src/nimmy

proc runTestsInDir(dir, label: string, isErrorTests: bool, passed: var int, failed: var int) =
  if not dirExists(dir):
    return
  
  for kind, path in walkDir(dir):
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
    
    if isErrorTests:
      # Error tests should fail, and error message should contain expected text
      if errorMsg.len > 0 and expected in errorMsg:
        echo "PASS " & label & "/" & testName
        passed += 1
      elif errorMsg.len > 0:
        echo "FAIL " & label & "/" & testName
        echo "  Expected error containing: " & expected
        echo "  Actual error: " & errorMsg
        failed += 1
      else:
        echo "FAIL " & label & "/" & testName
        echo "  Expected error containing: " & expected
        echo "  But script succeeded with: " & actual.splitLines()[0] & "..."
        failed += 1
    else:
      # Normal tests should succeed and match expected output
      if errorMsg.len > 0:
        echo "FAIL " & label & "/" & testName
        echo "  Error: " & errorMsg
        failed += 1
      elif actual == expected:
        echo "PASS " & label & "/" & testName
        passed += 1
      else:
        echo "FAIL " & label & "/" & testName
        echo "  Expected: " & expected.splitLines()[0] & "..."
        echo "  Actual:   " & actual.splitLines()[0] & "..."
        failed += 1

proc runTests() =
  let baseDir = currentSourcePath().parentDir()
  let scriptsDir = baseDir / "scripts"
  let errorsDir = baseDir / "errors"
  let syntaxDir = baseDir / "syntax"
  
  doAssert dirExists(scriptsDir), "Scripts directory not found: " & scriptsDir
  
  var passed, failed = 0
  
  # Run normal tests from scripts/
  runTestsInDir(scriptsDir, "scripts", isErrorTests = false, passed, failed)
  
  # Run runtime error tests from errors/
  runTestsInDir(errorsDir, "errors", isErrorTests = true, passed, failed)
  
  # Run syntax error tests from syntax/
  runTestsInDir(syntaxDir, "syntax", isErrorTests = true, passed, failed)
  
  echo ""
  echo "Results: " & $passed & " passed, " & $failed & " failed"
  doAssert failed == 0, "Some tests failed"

echo "Running Nimmy tests..."
runTests()
