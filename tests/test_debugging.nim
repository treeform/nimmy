## test_debugging.nim
## Unit tests for debugging primitives: step, stepInto, stepOver, stepOut, 
## breakpoints, and continue.
##
## Design: Each test creates a VM, loads code, calls debugging functions,
## and asserts correct state. Tests verify we can resume and complete execution.

import
  ../src/nimmy/[types, parser, vm]

# =============================================================================
# Test Helpers
# =============================================================================

var testsPassed* = 0
var testsFailed* = 0

proc createVM(): VM =
  result = newVM()
  
  # Add echo builtin (captures output)
  result.addProc("echo") do (args: seq[Value]) -> Value:
    nilValue()

template test(name: string, body: untyped) =
  try:
    body
    echo "  PASS: " & name
    testsPassed += 1
  except AssertionDefect as e:
    echo "  FAIL: " & name
    echo "    " & e.msg
    testsFailed += 1
  except CatchableError as e:
    echo "  FAIL: " & name & " (exception)"
    echo "    " & e.msg
    testsFailed += 1

# =============================================================================
# Test: Basic Step (same as stepInto)
# =============================================================================

proc testBasicStep() =
  test "basic step":
    let vm = createVM()
    let code = """
let a = 1
let b = 2
let c = 3
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    doAssert not vm.isFinished
    
    vm.step()
    doAssert vm.currentLine == 2
    
    vm.step()
    doAssert vm.currentLine == 3
    
    vm.step()
    doAssert vm.isFinished
    
    doAssert vm.currentScope.lookup("a").intVal == 1
    doAssert vm.currentScope.lookup("b").intVal == 2
    doAssert vm.currentScope.lookup("c").intVal == 3

# =============================================================================
# Test: Step Into Function
# =============================================================================

proc testStepIntoFunction() =
  test "stepInto function":
    let vm = createVM()
    let code = """
proc add(a, b) =
  return a + b

let result = add(3, 4)
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    vm.stepInto()
    
    doAssert vm.currentLine == 4
    vm.stepInto()
    
    doAssert vm.currentLine == 2, "Should be inside function at line 2, got " & $vm.currentLine
    vm.stepInto()
    
    doAssert vm.isFinished
    doAssert vm.currentScope.lookup("result").intVal == 7

# =============================================================================
# Test: Step Over Function
# =============================================================================

proc testStepOverFunction() =
  test "stepOver function":
    let vm = createVM()
    let code = """
proc add(a, b) =
  let sum = a + b
  return sum

let x = add(3, 4)
let y = 10
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    vm.stepOver()
    
    doAssert vm.currentLine == 5
    vm.stepOver()
    
    doAssert vm.currentLine == 6, "Should be at line 6 after stepOver, got " & $vm.currentLine
    
    vm.stepOver()
    doAssert vm.isFinished
    
    doAssert vm.currentScope.lookup("x").intVal == 7
    doAssert vm.currentScope.lookup("y").intVal == 10

# =============================================================================
# Test: Step Out of Function
# =============================================================================

proc testStepOutOfFunction() =
  test "stepOut of function":
    let vm = createVM()
    let code = """
proc compute(n) =
  let a = n * 2
  let b = a + 1
  return b

let result = compute(5)
let done = true
"""
    let ast = parse(code)
    vm.load(ast)
    
    vm.step()  # past proc def, now at line 6
    doAssert vm.currentLine == 6
    
    vm.step()  # now inside function at line 2
    doAssert vm.currentLine == 2, "Should be at line 2, got " & $vm.currentLine
    
    vm.stepOut()
    
    doAssert vm.currentLine == 7, "Should be at line 7 after stepOut, got " & $vm.currentLine
    doAssert not vm.isFinished
    
    vm.step()
    doAssert vm.isFinished
    
    doAssert vm.currentScope.lookup("result").intVal == 11
    doAssert vm.currentScope.lookup("done").boolVal == true

# =============================================================================
# Test: Breakpoints - Add/Remove/Has
# =============================================================================

proc testBreakpointAPI() =
  test "breakpoint API":
    let vm = createVM()
    
    doAssert not vm.hasBreakpoint(5)
    
    vm.addBreakpoint(5)
    doAssert vm.hasBreakpoint(5)
    
    vm.addBreakpoint(10)
    vm.addBreakpoint(15)
    doAssert vm.hasBreakpoint(10)
    doAssert vm.hasBreakpoint(15)
    
    vm.removeBreakpoint(10)
    doAssert not vm.hasBreakpoint(10)
    doAssert vm.hasBreakpoint(5)
    doAssert vm.hasBreakpoint(15)
    
    vm.clearBreakpoints()
    doAssert not vm.hasBreakpoint(5)
    doAssert not vm.hasBreakpoint(15)

# =============================================================================
# Test: Continue to Breakpoint
# =============================================================================

proc testContinueToBreakpoint() =
  test "continue to breakpoint":
    let vm = createVM()
    let code = """
let a = 1
let b = 2
let c = 3
let d = 4
let e = 5
"""
    let ast = parse(code)
    vm.load(ast)
    
    vm.addBreakpoint(3)
    vm.continueExecution()
    
    doAssert vm.currentLine == 3, "Should have stopped at breakpoint line 3, got " & $vm.currentLine
    doAssert not vm.isFinished
    
    doAssert vm.currentScope.lookup("a").intVal == 1
    doAssert vm.currentScope.lookup("b").intVal == 2
    
    vm.continueExecution()
    doAssert vm.isFinished
    
    doAssert vm.currentScope.lookup("c").intVal == 3
    doAssert vm.currentScope.lookup("d").intVal == 4
    doAssert vm.currentScope.lookup("e").intVal == 5

# =============================================================================
# Test: Breakpoint Inside Function
# =============================================================================

proc testBreakpointInsideFunction() =
  test "breakpoint inside function":
    let vm = createVM()
    let code = """
proc compute(n) =
  let a = n * 2
  let b = a + 1
  return b

let result = compute(5)
"""
    let ast = parse(code)
    vm.load(ast)
    
    vm.addBreakpoint(3)
    vm.continueExecution()
    
    doAssert vm.currentLine == 3, "Should stop at line 3 inside function, got " & $vm.currentLine
    doAssert not vm.isFinished
    
    doAssert vm.currentScope.lookup("a").intVal == 10
    
    vm.continueExecution()
    doAssert vm.isFinished
    
    doAssert vm.globalScope.lookup("result").intVal == 11

# =============================================================================
# Test: Multiple Breakpoints
# =============================================================================

proc testMultipleBreakpoints() =
  test "multiple breakpoints":
    let vm = createVM()
    let code = """
let a = 1
let b = 2
let c = 3
let d = 4
let e = 5
"""
    let ast = parse(code)
    vm.load(ast)
    
    vm.addBreakpoint(2)
    vm.addBreakpoint(4)
    
    vm.continueExecution()
    doAssert vm.currentLine == 2, "Should stop at line 2, got " & $vm.currentLine
    
    vm.continueExecution()
    doAssert vm.currentLine == 4, "Should stop at line 4, got " & $vm.currentLine
    
    vm.continueExecution()
    doAssert vm.isFinished

# =============================================================================
# Test: Nested Function Step Out
# =============================================================================

proc testNestedFunctionStepOut() =
  test "stepOut from nested function":
    let vm = createVM()
    let code = """
proc inner(n) =
  let x = n * 2
  return x

proc outer(n) =
  let y = inner(n)
  return y + 1

let result = outer(5)
"""
    let ast = parse(code)
    vm.load(ast)
    
    vm.step()  # proc inner
    vm.step()  # proc outer
    doAssert vm.currentLine == 9
    
    vm.step()
    doAssert vm.currentLine == 6  # inside outer
    
    vm.step()
    doAssert vm.currentLine == 2  # inside inner
    
    vm.stepOut()
    doAssert vm.currentLine == 7, "After stepOut of inner, should be at line 7, got " & $vm.currentLine
    
    while not vm.isFinished:
      vm.step()
    
    doAssert vm.globalScope.lookup("result").intVal == 11

# =============================================================================
# Test: Step After Breakpoint
# =============================================================================

proc testStepAfterBreakpoint() =
  test "step after hitting breakpoint":
    let vm = createVM()
    let code = """
let a = 1
let b = 2
let c = 3
"""
    let ast = parse(code)
    vm.load(ast)
    
    vm.addBreakpoint(2)
    vm.continueExecution()
    doAssert vm.currentLine == 2
    
    vm.step()  # execute line 2, move to line 3
    doAssert vm.currentLine == 3
    
    vm.step()  # execute line 3, finish
    doAssert vm.isFinished

# =============================================================================
# Test: Call Depth
# =============================================================================

proc testCallDepth() =
  test "call depth":
    let vm = createVM()
    let code = """
proc foo() =
  let x = 1
  return x

let result = foo()
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.callDepth() == 0
    
    vm.step()  # proc foo
    doAssert vm.callDepth() == 0
    
    vm.step()  # let result = foo() - enters foo
    doAssert vm.callDepth() == 1, "Inside foo, depth should be 1, got " & $vm.callDepth()
    
    vm.step()  # let x = 1
    doAssert vm.callDepth() == 1
    
    vm.step()  # return x - exits function
    doAssert vm.isFinished
    doAssert vm.callDepth() == 0

# =============================================================================
# Test: Resume After Any Debug Action
# =============================================================================

proc testResumeAfterDebugActions() =
  test "resume after various debug actions":
    let vm = createVM()
    let code = """
proc double(n) =
  return n * 2

let a = 1
let b = double(a)
let c = double(b)
let d = c + 1
"""
    let ast = parse(code)
    
    # Test 1: Resume after step
    vm.load(ast)
    vm.step()
    vm.step()
    while not vm.isFinished:
      vm.step()
    doAssert vm.globalScope.lookup("d").intVal == 5
    
    # Test 2: Resume after stepOver
    vm.load(ast)
    vm.stepOver()  # proc def
    vm.stepOver()  # let a
    vm.stepOver()  # let b (runs double)
    while not vm.isFinished:
      vm.step()
    doAssert vm.globalScope.lookup("d").intVal == 5
    
    # Test 3: Resume after stepOut
    vm.load(ast)
    vm.step()  # proc def
    vm.step()  # let a
    vm.step()  # into double
    vm.stepOut()  # out of double
    while not vm.isFinished:
      vm.step()
    doAssert vm.globalScope.lookup("d").intVal == 5
    
    # Test 4: Resume after breakpoint
    vm.load(ast)
    vm.addBreakpoint(6)
    vm.continueExecution()
    doAssert vm.currentLine == 6
    while not vm.isFinished:
      vm.step()
    doAssert vm.globalScope.lookup("d").intVal == 5

# =============================================================================
# Run All Tests
# =============================================================================

proc runDebuggingTests*(): tuple[passed: int, failed: int] =
  testsPassed = 0
  testsFailed = 0
  
  echo "Running debugging tests..."
  
  testBasicStep()
  testStepIntoFunction()
  testStepOverFunction()
  testStepOutOfFunction()
  testBreakpointAPI()
  testContinueToBreakpoint()
  testBreakpointInsideFunction()
  testMultipleBreakpoints()
  testNestedFunctionStepOut()
  testStepAfterBreakpoint()
  testCallDepth()
  testResumeAfterDebugActions()
  
  result = (testsPassed, testsFailed)

# =============================================================================
# Main
# =============================================================================

when isMainModule:
  let (passed, failed) = runDebuggingTests()
  echo ""
  echo "Debugging tests: " & $passed & " passed, " & $failed & " failed"
  if failed > 0:
    quit(1)
