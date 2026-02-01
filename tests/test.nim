## test.nim
## Gold master test harness for Nimmy
##
## This test runner executes all .nimmy scripts in the tests/scripts directory
## and compares their output to corresponding .txt files.

import std/[os, strutils, strformat, terminal, sequtils]
import ../src/nimmy

type
  TestResult = object
    name: string
    passed: bool
    expected: string
    actual: string
    error: string

proc runTests(): seq[TestResult] =
  result = @[]
  let scriptsDir = currentSourcePath().parentDir() / "scripts"
  
  if not dirExists(scriptsDir):
    echo fmt"Error: Scripts directory not found: {scriptsDir}"
    return
  
  for kind, path in walkDir(scriptsDir):
    if kind != pcFile:
      continue
    if not path.endsWith(".nimmy"):
      continue
    
    let testName = path.extractFilename().changeFileExt("")
    let expectedPath = path.changeFileExt(".txt")
    
    var testResult = TestResult(name: testName)
    
    # Check if expected output file exists
    if not fileExists(expectedPath):
      testResult.passed = false
      testResult.error = "Missing expected output file: " & expectedPath.extractFilename()
      result.add(testResult)
      continue
    
    # Read expected output (normalize line endings)
    testResult.expected = readFile(expectedPath).replace("\r\n", "\n").strip()
    
    # Run the script
    try:
      let nvm = newNimmyVM()
      let output = nvm.runFile(path)
      testResult.actual = output.replace("\r\n", "\n").strip()
      testResult.passed = testResult.actual == testResult.expected
    except NimmyError as e:
      testResult.passed = false
      testResult.actual = ""
      testResult.error = fmt"{e.msg}"
    except CatchableError as e:
      testResult.passed = false
      testResult.actual = ""
      testResult.error = fmt"Unexpected error: {e.msg}"
    
    result.add(testResult)

proc printResults(results: seq[TestResult]) =
  var passed = 0
  var failed = 0
  
  echo ""
  echo "=" .repeat(60)
  echo "NIMMY TEST RESULTS"
  echo "=" .repeat(60)
  echo ""
  
  for res in results:
    if res.passed:
      passed += 1
      stdout.styledWrite(fgGreen, "PASS")
      echo fmt" {res.name}"
    else:
      failed += 1
      stdout.styledWrite(fgRed, "FAIL")
      echo fmt" {res.name}"
      
      if res.error.len > 0:
        echo fmt"  Error: {res.error}"
      else:
        echo "  Expected:"
        for line in res.expected.splitLines():
          echo fmt"    {line}"
        echo "  Actual:"
        for line in res.actual.splitLines():
          echo fmt"    {line}"
      echo ""
  
  echo ""
  echo "-" .repeat(60)
  let total = passed + failed
  if failed == 0:
    stdout.styledWrite(fgGreen, fmt"All {total} tests passed!")
  else:
    stdout.styledWrite(fgYellow, fmt"{passed}/{total} tests passed, ")
    stdout.styledWrite(fgRed, fmt"{failed} failed")
  echo ""
  echo ""

proc main() =
  echo "Running Nimmy tests..."
  let results = runTests()
  printResults(results)
  
  # Exit with non-zero status if any tests failed
  let failed = results.filterIt(not it.passed).len
  if failed > 0:
    quit(1)

when isMainModule:
  main()
