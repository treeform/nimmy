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

proc createVM(): VM =
  result = newVM()
  
  # Add echo builtin (captures output)
  result.addProc("echo") do (args: seq[Value]) -> Value:
    nilValue()

# =============================================================================
# Test: Basic Step (same as stepInto)
# =============================================================================

proc testBasicStep() =
  echo "Testing basic step..."
  
  let vm = createVM()
  let code = """
let a = 1
let b = 2
let c = 3
"""
  let ast = parse(code)
  vm.load(ast)
  
  # Initial state
  doAssert vm.currentLine == 1
  doAssert not vm.isFinished
  
  # Step through each statement
  vm.step()
  doAssert vm.currentLine == 2
  
  vm.step()
  doAssert vm.currentLine == 3
  
  vm.step()
  doAssert vm.isFinished
  
  # Verify values
  doAssert vm.currentScope.lookup("a").intVal == 1
  doAssert vm.currentScope.lookup("b").intVal == 2
  doAssert vm.currentScope.lookup("c").intVal == 3
  
  echo "  PASS: basic step"

# =============================================================================
# Test: Step Into Function
# =============================================================================

proc testStepIntoFunction() =
  echo "Testing stepInto function..."
  
  let vm = createVM()
  let code = """
proc add(a, b) =
  return a + b

let result = add(3, 4)
"""
  let ast = parse(code)
  vm.load(ast)
  
  # Line 1: proc definition
  doAssert vm.currentLine == 1
  vm.stepInto()
  
  # Line 4: let result = add(3, 4)
  doAssert vm.currentLine == 4
  vm.stepInto()
  
  # Now inside function at line 2
  doAssert vm.currentLine == 2, "Should be inside function at line 2, got " & $vm.currentLine
  vm.stepInto()
  
  # Function returned, execution finished
  doAssert vm.isFinished
  
  # Verify result
  doAssert vm.currentScope.lookup("result").intVal == 7
  
  echo "  PASS: stepInto function"

# =============================================================================
# Test: Step Over Function
# =============================================================================

proc testStepOverFunction() =
  echo "Testing stepOver function..."
  
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
  
  # Line 1: proc definition
  doAssert vm.currentLine == 1
  vm.stepOver()
  
  # Line 5: let x = add(3, 4)
  doAssert vm.currentLine == 5
  
  # Step OVER the function call - should execute entire function
  vm.stepOver()
  
  # Should be at line 6, not inside the function
  doAssert vm.currentLine == 6, "Should be at line 6 after stepOver, got " & $vm.currentLine
  
  # Complete execution
  vm.stepOver()
  doAssert vm.isFinished
  
  # Verify values
  doAssert vm.currentScope.lookup("x").intVal == 7
  doAssert vm.currentScope.lookup("y").intVal == 10
  
  echo "  PASS: stepOver function"

# =============================================================================
# Test: Step Out of Function
# =============================================================================

proc testStepOutOfFunction() =
  echo "Testing stepOut of function..."
  
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
  
  # Step to proc definition
  vm.step()  # past proc def, now at line 6
  doAssert vm.currentLine == 6
  
  # Step into the function call
  vm.step()  # now inside function at line 2
  doAssert vm.currentLine == 2, "Should be at line 2, got " & $vm.currentLine
  
  # Step out - should run rest of function and return
  vm.stepOut()
  
  # Should be at line 7 (after function returned)
  doAssert vm.currentLine == 7, "Should be at line 7 after stepOut, got " & $vm.currentLine
  doAssert not vm.isFinished
  
  # Complete execution
  vm.step()
  doAssert vm.isFinished
  
  # Verify values
  doAssert vm.currentScope.lookup("result").intVal == 11  # 5*2+1
  doAssert vm.currentScope.lookup("done").boolVal == true
  
  echo "  PASS: stepOut of function"

# =============================================================================
# Test: Breakpoints - Add/Remove/Has
# =============================================================================

proc testBreakpointAPI() =
  echo "Testing breakpoint API..."
  
  let vm = createVM()
  
  # Initially no breakpoints
  doAssert not vm.hasBreakpoint(5)
  
  # Add breakpoint
  vm.addBreakpoint(5)
  doAssert vm.hasBreakpoint(5)
  
  # Add more breakpoints
  vm.addBreakpoint(10)
  vm.addBreakpoint(15)
  doAssert vm.hasBreakpoint(10)
  doAssert vm.hasBreakpoint(15)
  
  # Remove breakpoint
  vm.removeBreakpoint(10)
  doAssert not vm.hasBreakpoint(10)
  doAssert vm.hasBreakpoint(5)
  doAssert vm.hasBreakpoint(15)
  
  # Clear all
  vm.clearBreakpoints()
  doAssert not vm.hasBreakpoint(5)
  doAssert not vm.hasBreakpoint(15)
  
  echo "  PASS: breakpoint API"

# =============================================================================
# Test: Continue to Breakpoint
# =============================================================================

proc testContinueToBreakpoint() =
  echo "Testing continue to breakpoint..."
  
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
  
  # Set breakpoint on line 3
  vm.addBreakpoint(3)
  
  # Continue - should stop at line 3
  vm.continueExecution()
  
  doAssert vm.currentLine == 3, "Should have stopped at breakpoint line 3, got " & $vm.currentLine
  doAssert not vm.isFinished
  
  # Variables a and b should be defined
  doAssert vm.currentScope.lookup("a").intVal == 1
  doAssert vm.currentScope.lookup("b").intVal == 2
  
  # Continue again - no more breakpoints, should finish
  vm.continueExecution()
  doAssert vm.isFinished
  
  # All variables should be defined
  doAssert vm.currentScope.lookup("c").intVal == 3
  doAssert vm.currentScope.lookup("d").intVal == 4
  doAssert vm.currentScope.lookup("e").intVal == 5
  
  echo "  PASS: continue to breakpoint"

# =============================================================================
# Test: Breakpoint Inside Function
# =============================================================================

proc testBreakpointInsideFunction() =
  echo "Testing breakpoint inside function..."
  
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
  
  # Set breakpoint on line 3 (inside function)
  vm.addBreakpoint(3)
  
  # Continue - should stop inside function at line 3
  vm.continueExecution()
  
  doAssert vm.currentLine == 3, "Should stop at line 3 inside function, got " & $vm.currentLine
  doAssert not vm.isFinished
  
  # Should be inside function, check local variable 'a'
  doAssert vm.currentScope.lookup("a").intVal == 10  # 5 * 2
  
  # Continue to finish
  vm.continueExecution()
  doAssert vm.isFinished
  
  # Verify final result
  doAssert vm.globalScope.lookup("result").intVal == 11
  
  echo "  PASS: breakpoint inside function"

# =============================================================================
# Test: Multiple Breakpoints
# =============================================================================

proc testMultipleBreakpoints() =
  echo "Testing multiple breakpoints..."
  
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
  
  # Set breakpoints on lines 2 and 4
  vm.addBreakpoint(2)
  vm.addBreakpoint(4)
  
  # Continue - should stop at line 2
  vm.continueExecution()
  doAssert vm.currentLine == 2, "Should stop at line 2, got " & $vm.currentLine
  
  # Continue - should stop at line 4
  vm.continueExecution()
  doAssert vm.currentLine == 4, "Should stop at line 4, got " & $vm.currentLine
  
  # Continue - should finish
  vm.continueExecution()
  doAssert vm.isFinished
  
  echo "  PASS: multiple breakpoints"

# =============================================================================
# Test: Nested Function Step Out
# =============================================================================

proc testNestedFunctionStepOut() =
  echo "Testing stepOut from nested function..."
  
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
  
  # Skip proc definitions
  vm.step()  # proc inner
  vm.step()  # proc outer
  doAssert vm.currentLine == 9
  
  # Step into outer
  vm.step()
  doAssert vm.currentLine == 6  # inside outer
  
  # Step into inner
  vm.step()
  doAssert vm.currentLine == 2  # inside inner
  
  # Step out of inner - should return to outer
  vm.stepOut()
  doAssert vm.currentLine == 7, "After stepOut of inner, should be at line 7, got " & $vm.currentLine
  
  # Complete execution
  while not vm.isFinished:
    vm.step()
  
  doAssert vm.globalScope.lookup("result").intVal == 11  # (5*2) + 1
  
  echo "  PASS: stepOut from nested function"

# =============================================================================
# Test: Step After Breakpoint
# =============================================================================

proc testStepAfterBreakpoint() =
  echo "Testing step after hitting breakpoint..."
  
  let vm = createVM()
  let code = """
let a = 1
let b = 2
let c = 3
"""
  let ast = parse(code)
  vm.load(ast)
  
  # Set breakpoint on line 2
  vm.addBreakpoint(2)
  
  # Continue to breakpoint
  vm.continueExecution()
  doAssert vm.currentLine == 2
  
  # Now step manually
  vm.step()  # execute line 2, move to line 3
  doAssert vm.currentLine == 3
  
  vm.step()  # execute line 3, finish
  doAssert vm.isFinished
  
  echo "  PASS: step after breakpoint"

# =============================================================================
# Test: Call Depth
# =============================================================================

proc testCallDepth() =
  echo "Testing call depth..."
  
  let vm = createVM()
  let code = """
proc foo() =
  let x = 1
  return x

let result = foo()
"""
  let ast = parse(code)
  vm.load(ast)
  
  # At top level
  doAssert vm.callDepth() == 0
  
  # Step past proc definition
  vm.step()  # proc foo
  doAssert vm.callDepth() == 0
  
  # Step into foo
  vm.step()  # let result = foo() - enters foo
  doAssert vm.callDepth() == 1, "Inside foo, depth should be 1, got " & $vm.callDepth()
  
  # Step inside function
  vm.step()  # let x = 1
  doAssert vm.callDepth() == 1
  
  # Step on return - exits function
  vm.step()  # return x
  doAssert vm.isFinished
  doAssert vm.callDepth() == 0
  
  echo "  PASS: call depth"

# =============================================================================
# Test: Resume After Any Debug Action
# =============================================================================

proc testResumeAfterDebugActions() =
  echo "Testing resume after various debug actions..."
  
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
  doAssert vm.globalScope.lookup("d").intVal == 5  # ((1*2)*2)+1
  
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
  
  echo "  PASS: resume after debug actions"

# =============================================================================
# Main
# =============================================================================

when isMainModule:
  echo "Running Nimmy debugging tests..."
  echo ""
  
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
  
  echo ""
  echo "All debugging tests passed!"
