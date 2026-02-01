## test_all.nim
## Runs all Nimmy tests and reports combined results.

import
  std/strutils,
  test_stepping,
  test_debugging,
  test_interactive,
  tests

proc main() =
  var totalPassed = 0
  var totalFailed = 0
  
  echo "=" .repeat(60)
  echo "NIMMY TEST SUITE"
  echo "=" .repeat(60)
  echo ""
  
  # Run stepping tests
  let (steppingPassed, steppingFailed) = runSteppingTests()
  totalPassed += steppingPassed
  totalFailed += steppingFailed
  echo ""
  
  # Run debugging tests
  let (debuggingPassed, debuggingFailed) = runDebuggingTests()
  totalPassed += debuggingPassed
  totalFailed += debuggingFailed
  echo ""
  
  # Run interactive tests
  let (interactivePassed, interactiveFailed) = runInteractiveTests()
  totalPassed += interactivePassed
  totalFailed += interactiveFailed
  echo ""
  
  # Run gold master tests
  let (goldPassed, goldFailed) = runGoldMasterTests()
  totalPassed += goldPassed
  totalFailed += goldFailed
  echo ""
  
  # Summary
  echo "=" .repeat(60)
  echo "SUMMARY"
  echo "=" .repeat(60)
  echo ""
  echo "  Stepping tests:     " & $steppingPassed & " passed, " & $steppingFailed & " failed"
  echo "  Debugging tests:    " & $debuggingPassed & " passed, " & $debuggingFailed & " failed"
  echo "  Interactive tests:  " & $interactivePassed & " passed, " & $interactiveFailed & " failed"
  echo "  Gold master tests:  " & $goldPassed & " passed, " & $goldFailed & " failed"
  echo ""
  echo "  TOTAL: " & $totalPassed & " passed, " & $totalFailed & " failed"
  echo ""
  
  if totalFailed > 0:
    echo "FAILED"
    quit(1)
  else:
    echo "ALL TESTS PASSED"

when isMainModule:
  main()
