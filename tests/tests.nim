## Gold master tests for Nimmy.
## Runs all .nimmy scripts and compares output to .txt files.
## Scripts in errors/ folder are expected to fail with specific error messages.
import
  std/[os, strutils],
  ../src/nimmy

proc runTestsInDir(dir: string, isErrorTests: bool, passed: var int, failed: var int) =
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
        echo "PASS " & testName
        passed += 1
      elif errorMsg.len > 0:
        echo "FAIL " & testName
        echo "  Expected error containing: " & expected
        echo "  Actual error: " & errorMsg
        failed += 1
      else:
        echo "FAIL " & testName
        echo "  Expected error containing: " & expected
        echo "  But script succeeded with: " & actual.splitLines()[0] & "..."
        failed += 1
    else:
      # Normal tests should succeed and match expected output
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

proc runTests() =
  let baseDir = currentSourcePath().parentDir()
  let scriptsDir = baseDir / "scripts"
  let errorsDir = baseDir / "errors"
  
  doAssert dirExists(scriptsDir), "Scripts directory not found: " & scriptsDir
  
  var passed, failed = 0
  
  # Run normal tests from scripts/
  runTestsInDir(scriptsDir, isErrorTests = false, passed, failed)
  
  # Run error tests from errors/
  runTestsInDir(errorsDir, isErrorTests = true, passed, failed)
  
  echo ""
  echo "Results: " & $passed & " passed, " & $failed & " failed"
  doAssert failed == 0, "Some tests failed"

echo "Running Nimmy tests..."
runTests()
