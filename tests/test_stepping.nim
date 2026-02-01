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

proc createVM(): VM =
  result = newVM()
  
  # Add echo builtin
  result.addProc("echo") do (args: seq[Value]) -> Value:
    nilValue()

# =============================================================================
# Test: Simple Sequential Statements
# =============================================================================

proc testSimpleSequential() =
  echo "Testing simple sequential statements..."
  
  let vm = createVM()
  let code = """
let a = 1
let b = 2
let c = 3
"""
  let ast = parse(code)
  vm.load(ast)
  
  # Before any steps
  doAssert not vm.isFinished
  doAssert vm.currentLine == 1, "Should start at line 1, got " & $vm.currentLine
  
  # Step 1: execute let a = 1
  vm.step()
  doAssert vm.currentLine == 2, "After step 1, should be at line 2, got " & $vm.currentLine
  
  # Step 2: execute let b = 2
  vm.step()
  doAssert vm.currentLine == 3, "After step 2, should be at line 3, got " & $vm.currentLine
  
  # Step 3: execute let c = 3
  vm.step()
  doAssert vm.isFinished, "Should be finished after 3 steps"
  
  echo "  PASS: simple sequential statements"

# =============================================================================
# Test: Variable Values After Steps
# =============================================================================

proc testVariableValues() =
  echo "Testing variable values after steps..."
  
  let vm = createVM()
  let code = """
let x = 42
let y = x + 8
"""
  let ast = parse(code)
  vm.load(ast)
  
  # Before first step
  doAssert vm.currentScope.lookup("x").isNil, "x should not exist before step"
  
  # Step 1: execute let x = 42
  vm.step()
  let xVal = vm.currentScope.lookup("x")
  doAssert not xVal.isNil, "x should exist after step 1"
  doAssert xVal.kind == vkInt and xVal.intVal == 42, "x should be 42"
  
  # Step 2: execute let y = x + 8
  vm.step()
  let yVal = vm.currentScope.lookup("y")
  doAssert not yVal.isNil, "y should exist after step 2"
  doAssert yVal.kind == vkInt and yVal.intVal == 50, "y should be 50"
  
  doAssert vm.isFinished
  
  echo "  PASS: variable values after steps"

# =============================================================================
# Test: Function Definition and Call
# =============================================================================

proc testFunctionCall() =
  echo "Testing function definition and call..."
  
  let vm = createVM()
  let code = """
proc foo() =
  let x = 10
  return x

let result = foo()
"""
  let ast = parse(code)
  vm.load(ast)
  
  # Line 1: proc definition
  doAssert vm.currentLine == 1
  vm.step()
  
  # Line 5: let result = foo() - this step should ENTER the function
  doAssert vm.currentLine == 5, "Should be at line 5, got " & $vm.currentLine
  vm.step()
  
  # Now we should be inside foo(), at line 2
  doAssert vm.currentLine == 2, "Should be inside function at line 2, got " & $vm.currentLine
  vm.step()
  
  # Line 3: return x
  doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
  vm.step()
  
  # Function returned, execution should be finished
  doAssert vm.isFinished, "Should be finished"
  
  echo "  PASS: function definition and call"

# =============================================================================
# Test: Nested Function Calls
# =============================================================================

proc testNestedFunctions() =
  echo "Testing nested function calls..."
  
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
  
  # Line 1: proc inner
  doAssert vm.currentLine == 1
  vm.step()
  
  # Line 4: proc outer
  doAssert vm.currentLine == 4
  vm.step()
  
  # Line 8: let result = outer(5) - enters outer
  doAssert vm.currentLine == 8
  vm.step()
  
  # Line 5: let x = inner(n) - inside outer, enters inner
  doAssert vm.currentLine == 5, "Should be at line 5, got " & $vm.currentLine
  vm.step()
  
  # Line 2: return n * 2 - inside inner
  doAssert vm.currentLine == 2, "Should be at line 2, got " & $vm.currentLine
  vm.step()
  
  # Line 6: return x + 1 - back in outer
  doAssert vm.currentLine == 6, "Should be at line 6, got " & $vm.currentLine
  vm.step()
  
  # Finished
  doAssert vm.isFinished
  
  echo "  PASS: nested function calls"

# =============================================================================
# Test: If Statement - True Branch
# =============================================================================

proc testIfTrue() =
  echo "Testing if statement (true branch)..."
  
  let vm = createVM()
  let code = """
let x = 5
if x > 3:
  let y = 10
let z = 20
"""
  let ast = parse(code)
  vm.load(ast)
  
  # Line 1: let x = 5
  doAssert vm.currentLine == 1
  vm.step()
  
  # Line 2: if statement (condition is true, so we enter body)
  doAssert vm.currentLine == 2
  vm.step()
  
  # Line 3: let y = 10 (inside if body)
  doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
  vm.step()
  
  # Line 4: let z = 20
  doAssert vm.currentLine == 4, "Should be at line 4, got " & $vm.currentLine
  vm.step()
  
  doAssert vm.isFinished
  
  echo "  PASS: if statement (true branch)"

# =============================================================================
# Test: If Statement - False Branch (else)
# =============================================================================

proc testIfFalse() =
  echo "Testing if statement (false branch)..."
  
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
  
  # Line 1: let x = 1
  doAssert vm.currentLine == 1
  vm.step()
  
  # Line 2: if statement (condition is false, so we enter else)
  doAssert vm.currentLine == 2
  vm.step()
  
  # Line 5: let y = 20 (inside else body)
  doAssert vm.currentLine == 5, "Should be at line 5, got " & $vm.currentLine
  vm.step()
  
  # Line 6: let z = 30
  doAssert vm.currentLine == 6, "Should be at line 6, got " & $vm.currentLine
  vm.step()
  
  doAssert vm.isFinished
  
  echo "  PASS: if statement (false branch)"

# =============================================================================
# Test: For Loop
# =============================================================================

proc testForLoop() =
  echo "Testing for loop..."
  
  let vm = createVM()
  let code = """
var sum = 0
for i in 1..3:
  sum = sum + i
let done = true
"""
  let ast = parse(code)
  vm.load(ast)
  
  # Line 1: var sum = 0
  doAssert vm.currentLine == 1
  vm.step()
  
  # Line 2: for loop setup (i=1)
  doAssert vm.currentLine == 2
  vm.step()
  
  # Line 3: sum = sum + i (iteration 1, i=1)
  doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
  vm.step()
  
  # Line 3: sum = sum + i (iteration 2, i=2)
  doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
  vm.step()
  
  # Line 3: sum = sum + i (iteration 3, i=3)
  doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
  vm.step()
  
  # Line 4: let done = true
  doAssert vm.currentLine == 4, "Should be at line 4, got " & $vm.currentLine
  vm.step()
  
  doAssert vm.isFinished
  
  # Verify sum is correct
  let sumVal = vm.currentScope.lookup("sum")
  doAssert sumVal.intVal == 6, "sum should be 6, got " & $sumVal.intVal
  
  echo "  PASS: for loop"

# =============================================================================
# Test: While Loop
# =============================================================================

proc testWhileLoop() =
  echo "Testing while loop..."
  
  let vm = createVM()
  let code = """
var i = 0
while i < 3:
  i = i + 1
let done = true
"""
  let ast = parse(code)
  vm.load(ast)
  
  # Line 1: var i = 0
  doAssert vm.currentLine == 1
  vm.step()
  
  # Line 2: while condition check (i=0 < 3, true)
  doAssert vm.currentLine == 2
  vm.step()
  
  # Line 3: i = i + 1 (i becomes 1)
  doAssert vm.currentLine == 3
  vm.step()
  
  # Line 3: i = i + 1 (i becomes 2)
  doAssert vm.currentLine == 3
  vm.step()
  
  # Line 3: i = i + 1 (i becomes 3)
  doAssert vm.currentLine == 3
  vm.step()
  
  # Line 4: let done = true (loop exited because i >= 3)
  doAssert vm.currentLine == 4, "Should be at line 4, got " & $vm.currentLine
  vm.step()
  
  doAssert vm.isFinished
  
  echo "  PASS: while loop"

# =============================================================================
# Test: Early Return
# =============================================================================

proc testEarlyReturn() =
  echo "Testing early return..."
  
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
  
  # Line 1: proc test
  doAssert vm.currentLine == 1
  vm.step()
  
  # Line 6: let a = test(10) - enters function
  doAssert vm.currentLine == 6
  vm.step()
  
  # Line 2: if n > 5 (true, so enter body)
  doAssert vm.currentLine == 2, "Should be at line 2, got " & $vm.currentLine
  vm.step()
  
  # Line 3: return 100
  doAssert vm.currentLine == 3, "Should be at line 3, got " & $vm.currentLine
  vm.step()
  
  # Finished (early return, didn't reach line 4)
  doAssert vm.isFinished
  
  echo "  PASS: early return"

# =============================================================================
# Test: Break in Loop
# =============================================================================

proc testBreakInLoop() =
  echo "Testing break in loop..."
  
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
  
  # Line 1: var i = 0
  doAssert vm.currentLine == 1
  vm.step()
  
  # Line 2: while true
  doAssert vm.currentLine == 2
  vm.step()
  
  # Line 3: i = i + 1 (i becomes 1)
  doAssert vm.currentLine == 3
  vm.step()
  
  # Line 4: if i >= 2 (false, skip break)
  doAssert vm.currentLine == 4
  vm.step()
  
  # Line 3: i = i + 1 (i becomes 2)
  doAssert vm.currentLine == 3
  vm.step()
  
  # Line 4: if i >= 2 (true, enter body)
  doAssert vm.currentLine == 4
  vm.step()
  
  # Line 5: break
  doAssert vm.currentLine == 5
  vm.step()
  
  # Line 6: let done = true
  doAssert vm.currentLine == 6, "Should be at line 6, got " & $vm.currentLine
  vm.step()
  
  doAssert vm.isFinished
  
  echo "  PASS: break in loop"

# =============================================================================
# Main
# =============================================================================

when isMainModule:
  echo "Running Nimmy stepping tests..."
  echo ""
  
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
  
  echo ""
  echo "All stepping tests passed!"
