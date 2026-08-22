## test_stepping.nim
## Unit tests for VM stepping functionality
##
## The VM should have a step() function that advances execution by one statement.
## After each step, we can inspect the VM state to verify correctness.

import
  ../src/nimmy/[types, parser, vm]

# =============================================================================
# Test Helpers
# =============================================================================

var testsPassed* = 0
var testsFailed* = 0

proc createVM(): VM =
  result = newVM()
  
  # Add echo builtin
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
# Test: Simple Sequential Statements
# =============================================================================

proc testSimpleSequential() =
  test "simple sequential statements":
    let vm = createVM()
    let code = """
let a = 1
let b = 2
let c = 3
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert not vm.isFinished
    doAssert vm.currentLine == 1, "Should start at line 1, got " & $vm.currentLine
    
    vm.step()
    doAssert vm.currentLine == 2, "After step 1, should be at line 2, got " & $vm.currentLine
    
    vm.step()
    doAssert vm.currentLine == 3, "After step 2, should be at line 3, got " & $vm.currentLine
    
    vm.step()
    doAssert vm.isFinished, "Should be finished after 3 steps"

# =============================================================================
# Test: Variable Values After Steps
# =============================================================================

proc testVariableValues() =
  test "variable values after steps":
    let vm = createVM()
    let code = """
let x = 42
let y = x + 8
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentScope.lookup("x").isNil, "x should not exist before step"
    
    vm.step()
    let xVal = vm.currentScope.lookup("x")
    doAssert not xVal.isNil, "x should exist after step 1"
    doAssert xVal.kind == IntValue and xVal.intVal == 42, "x should be 42"
    
    vm.step()
    let yVal = vm.currentScope.lookup("y")
    doAssert not yVal.isNil, "y should exist after step 2"
    doAssert yVal.kind == IntValue and yVal.intVal == 50, "y should be 50"
    
    doAssert vm.isFinished

# =============================================================================
# Test: Function Definition and Call
# =============================================================================

proc testFunctionCall() =
  test "function definition and call":
    let vm = createVM()
    let code = """
proc foo() =
  let x = 10
  return x

let result = foo()
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    vm.step()
    
    doAssert vm.currentLine == 5, "Should be at line 5, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.currentLine == 2, "Should be inside function at line 2, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.isFinished, "Should be finished"

# =============================================================================
# Test: Nested Function Calls
# =============================================================================

proc testNestedFunctions() =
  test "nested function calls":
    let vm = createVM()
    let code = """
proc inner(n) =
  return n * 2

proc outer(n) =
  let x = inner(n)
  return x + 1

let result = outer(5)
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    vm.step()
    
    doAssert vm.currentLine == 4
    vm.step()
    
    doAssert vm.currentLine == 8
    vm.step()
    
    doAssert vm.currentLine == 5, "Should be at line 5, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.currentLine == 2, "Should be at line 2, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.currentLine == 6, "Should be at line 6, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.isFinished

# =============================================================================
# Test: If Statement - True Branch
# =============================================================================

proc testIfTrue() =
  test "if statement (true branch)":
    let vm = createVM()
    let code = """
let x = 5
if x > 3:
  let y = 10
let z = 20
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    vm.step()
    
    doAssert vm.currentLine == 2
    vm.step()
    
    doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.currentLine == 4, "Should be at line 4, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.isFinished

# =============================================================================
# Test: If Statement - False Branch (else)
# =============================================================================

proc testIfFalse() =
  test "if statement (false branch)":
    let vm = createVM()
    let code = """
let x = 1
if x > 3:
  let y = 10
else:
  let y = 20
let z = 30
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    vm.step()
    
    doAssert vm.currentLine == 2
    vm.step()
    
    doAssert vm.currentLine == 5, "Should be at line 5, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.currentLine == 6, "Should be at line 6, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.isFinished

# =============================================================================
# Test: For Loop
# =============================================================================

proc testForLoop() =
  test "for loop":
    let vm = createVM()
    let code = """
var sum = 0
for i in 1..3:
  sum = sum + i
let done = true
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    vm.step()
    
    doAssert vm.currentLine == 2
    vm.step()
    
    doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.currentLine == 4, "Should be at line 4, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.isFinished
    
    let sumVal = vm.currentScope.lookup("sum")
    doAssert sumVal.intVal == 6, "sum should be 6, got " & $sumVal.intVal

# =============================================================================
# Test: While Loop
# =============================================================================

proc testWhileLoop() =
  test "while loop":
    let vm = createVM()
    let code = """
var i = 0
while i < 3:
  i = i + 1
let done = true
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    vm.step()
    
    doAssert vm.currentLine == 2
    vm.step()
    
    doAssert vm.currentLine == 3
    vm.step()
    
    doAssert vm.currentLine == 3
    vm.step()
    
    doAssert vm.currentLine == 3
    vm.step()
    
    doAssert vm.currentLine == 4, "Should be at line 4, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.isFinished

# =============================================================================
# Test: Early Return
# =============================================================================

proc testEarlyReturn() =
  test "early return":
    let vm = createVM()
    let code = """
proc test(n) =
  if n > 5:
    return 100
  return n * 2

let a = test(10)
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    vm.step()
    
    doAssert vm.currentLine == 6
    vm.step()
    
    doAssert vm.currentLine == 2, "Should be at line 2, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.isFinished

# =============================================================================
# Test: Break in Loop
# =============================================================================

proc testBreakInLoop() =
  test "break in loop":
    let vm = createVM()
    let code = """
var i = 0
while true:
  i = i + 1
  if i >= 2:
    break
let done = true
"""
    let ast = parse(code)
    vm.load(ast)
    
    doAssert vm.currentLine == 1
    vm.step()
    
    doAssert vm.currentLine == 2
    vm.step()
    
    doAssert vm.currentLine == 3
    vm.step()
    
    doAssert vm.currentLine == 4
    vm.step()
    
    doAssert vm.currentLine == 3
    vm.step()
    
    doAssert vm.currentLine == 4
    vm.step()
    
    doAssert vm.currentLine == 5
    vm.step()
    
    doAssert vm.currentLine == 6, "Should be at line 6, got " & $vm.currentLine
    vm.step()
    
    doAssert vm.isFinished


# =============================================================================
# Test: Proc Call Inside an Expression Steps Into the Proc
# =============================================================================

proc testExpressionCallSteps() =
  test "proc call inside an if condition steps into the proc":
    let vm = createVM()
    let code = """
proc f() =
  let a = 1
  return true
if f():
  let b = 2
let c = 3
"""
    let ast = parse(code)
    vm.load(ast)

    doAssert vm.currentLine == 1
    vm.step()

    doAssert vm.currentLine == 4, "Should be at the if, got " & $vm.currentLine
    vm.step()

    doAssert vm.currentLine == 2, "Should be inside f, got " & $vm.currentLine
    doAssert vm.callDepth == 1
    vm.step()

    doAssert vm.currentLine == 3, "Should be at return, got " & $vm.currentLine
    vm.step()

    # The return also finishes the if and enters its body in the same step.
    doAssert vm.currentLine == 5, "Should be in the if body, got " & $vm.currentLine
    doAssert vm.callDepth == 0
    vm.step()

    doAssert vm.currentLine == 6, "Should be at line 6, got " & $vm.currentLine
    vm.step()

    doAssert vm.isFinished

  test "while condition call costs a step per statement of the proc":
    let vm = createVM()
    let code = """
var n = 0
proc tick() =
  n = n + 1
  return n < 3
while tick():
  discard
let done = true
"""
    let ast = parse(code)
    vm.load(ast)
    var steps = 0
    while not vm.isFinished:
      vm.step()
      steps += 1
      doAssert steps < 100, "runaway"
    doAssert vm.currentScope.lookup("n").intVal == 3
    # var, proc, while header, tick's 2 statements x3 calls, discard x2, let
    doAssert steps == 1 + 1 + 1 + 3 * 2 + 2 + 1, "steps=" & $steps

  test "two calls in one expression run one after the other":
    let vm = createVM()
    let code = """
proc f() =
  return 10
proc g() =
  return 5
let x = f() + g() * 2
"""
    let ast = parse(code)
    vm.load(ast)
    vm.step()
    vm.step()
    doAssert vm.currentLine == 5
    vm.step()
    doAssert vm.currentLine == 2, "Should be inside f, got " & $vm.currentLine
    vm.step()
    doAssert vm.currentLine == 4, "Should be inside g, got " & $vm.currentLine
    vm.step()
    doAssert vm.isFinished
    doAssert vm.currentScope.lookup("x").intVal == 20

  test "stepOver runs every call of the statement":
    let vm = createVM()
    let code = """
proc f() =
  return 10
proc g() =
  return 5
let x = f() + g()
let y = 1
"""
    let ast = parse(code)
    vm.load(ast)
    vm.stepOver()
    vm.stepOver()
    doAssert vm.currentLine == 5
    vm.stepOver()
    doAssert vm.currentLine == 6, "Should be past the calls, got " & $vm.currentLine
    doAssert vm.currentScope.lookup("x").intVal == 15

# =============================================================================
# Run All Tests
# =============================================================================

proc runSteppingTests*(): tuple[passed: int, failed: int] =
  testsPassed = 0
  testsFailed = 0
  
  echo "Running stepping tests..."
  
  testSimpleSequential()
  testVariableValues()
  testFunctionCall()
  testNestedFunctions()
  testIfTrue()
  testIfFalse()
  testForLoop()
  testWhileLoop()
  testEarlyReturn()
  testBreakInLoop()
  testExpressionCallSteps()
  
  result = (testsPassed, testsFailed)

# =============================================================================
# Main
# =============================================================================

when isMainModule:
  let (passed, failed) = runSteppingTests()
  echo ""
  echo "Stepping tests: " & $passed & " passed, " & $failed & " failed"
  if failed > 0:
    quit(1)
