## test_debugging.nim
## Unit tests for the Nimmy debugger functionality

import
  std/[sets, tables],
  ../src/nimmy/[types, parser, vm, debug]

# =============================================================================
# Test Helpers
# =============================================================================

proc createVM(): VM =
  result = newVM()
  
  # Add echo builtin for testing
  result.addProc("echo") do (args: seq[Value]) -> Value:
    discard  # Don't print, just capture
    nilValue()

# =============================================================================
# Test: Basic Breakpoint API
# =============================================================================

proc testBreakpointAPI() =
  echo "Testing breakpoint API..."
  
  let vm = createVM()
  let dbg = newDebugger(vm)
  
  # Initially no breakpoints
  doAssert dbg.breakpoints.len == 0
  doAssert not dbg.hasBreakpoint(5)
  
  # Add breakpoint
  dbg.addBreakpoint(5)
  doAssert dbg.breakpoints.len == 1
  doAssert dbg.hasBreakpoint(5)
  
  # Adding same breakpoint doesn't duplicate
  dbg.addBreakpoint(5)
  doAssert dbg.breakpoints.len == 1
  
  # Add more breakpoints
  dbg.addBreakpoint(10)
  dbg.addBreakpoint(15)
  doAssert dbg.breakpoints.len == 3
  
  # Remove breakpoint
  dbg.removeBreakpoint(10)
  doAssert dbg.breakpoints.len == 2
  doAssert not dbg.hasBreakpoint(10)
  
  # Clear all
  dbg.clearBreakpoints()
  doAssert dbg.breakpoints.len == 0
  
  echo "  PASS: breakpoint API"

# =============================================================================
# Test: Step Mode and Pause
# =============================================================================

proc testStepModeAPI() =
  echo "Testing step mode API..."
  
  let vm = createVM()
  let dbg = newDebugger(vm)
  
  # Initially not stepping or paused
  doAssert not dbg.stepMode
  doAssert not dbg.paused
  
  # Enable step mode
  dbg.enableStepMode()
  doAssert dbg.stepMode
  
  # Disable step mode
  dbg.disableStepMode()
  doAssert not dbg.stepMode
  
  # Pause/resume
  dbg.pause()
  doAssert dbg.paused
  dbg.resume()
  doAssert not dbg.paused
  
  echo "  PASS: step mode API"

# =============================================================================
# Test: Call Stack Tracking
# =============================================================================

proc testCallStackAPI() =
  echo "Testing call stack API..."
  
  let vm = createVM()
  let dbg = newDebugger(vm)
  
  # Initially at main
  doAssert dbg.callStack.len == 1
  doAssert dbg.callStack[0] == "<main>"
  
  # Push calls
  dbg.pushCall("foo")
  doAssert dbg.callStack.len == 2
  doAssert dbg.callStack[1] == "foo"
  
  dbg.pushCall("bar")
  doAssert dbg.callStack.len == 3
  doAssert dbg.callStack[2] == "bar"
  
  # Pop calls
  dbg.popCall()
  doAssert dbg.callStack.len == 2
  
  dbg.popCall()
  doAssert dbg.callStack.len == 1
  
  # Can't pop below main
  dbg.popCall()
  doAssert dbg.callStack.len == 1
  
  echo "  PASS: call stack API"

# =============================================================================
# Test: VM Debug Hooks - Statement Callback
# =============================================================================

proc testVMStatementHook() =
  echo "Testing VM statement hooks..."
  
  let vm = createVM()
  var statementsExecuted: seq[int] = @[]
  
  # Set up a hook that records each statement's line
  vm.onStatement = proc(line, col: int): bool =
    statementsExecuted.add(line)
    return true  # Continue execution
  
  let code = """
let x = 1
let y = 2
let z = x + y
"""
  
  let ast = parse(code)
  discard vm.eval(ast)
  
  # Should have recorded 3 statements
  doAssert statementsExecuted.len == 3, "Expected 3 statements, got " & $statementsExecuted.len
  doAssert 1 in statementsExecuted
  doAssert 2 in statementsExecuted
  doAssert 3 in statementsExecuted
  
  echo "  PASS: VM statement hooks"

# =============================================================================
# Test: VM Debug Hooks - Function Entry/Exit
# =============================================================================

proc testVMFunctionHooks() =
  echo "Testing VM function entry/exit hooks..."
  
  let vm = createVM()
  var callLog: seq[string] = @[]
  
  # Set up hooks for function entry/exit
  vm.onEnterFunction = proc(name: string) =
    callLog.add("enter:" & name)
  
  vm.onExitFunction = proc(name: string) =
    callLog.add("exit:" & name)
  
  let code = """
proc foo() =
  let x = 1
  return x

proc bar() =
  let y = foo()
  return y

let result = bar()
"""
  
  let ast = parse(code)
  discard vm.eval(ast)
  
  # Should have: enter bar, enter foo, exit foo, exit bar
  doAssert callLog.len == 4, "Expected 4 call events, got " & $callLog.len & ": " & $callLog
  doAssert callLog[0] == "enter:bar"
  doAssert callLog[1] == "enter:foo"
  doAssert callLog[2] == "exit:foo"
  doAssert callLog[3] == "exit:bar"
  
  echo "  PASS: VM function hooks"

# =============================================================================
# Test: Breakpoints Inside Functions
# =============================================================================

proc testBreakpointsInsideFunctions() =
  echo "Testing breakpoints inside functions..."
  
  let vm = createVM()
  var hitLines: seq[int] = @[]
  var breakpoints: HashSet[int] = [6].toHashSet  # Breakpoint on line 6
  
  # Hook that checks breakpoints
  vm.onStatement = proc(line, col: int): bool =
    if line in breakpoints:
      hitLines.add(line)
    return true  # Continue execution
  
  let code = """
proc greet(name) =
  let prefix = "Hello"
  let msg = prefix & ", " & name
  return msg

let result = greet("World")
"""
  # Line 1: proc greet(name) =
  # Line 2:   let prefix = "Hello"
  # Line 3:   let msg = prefix & ", " & name
  # Line 4:   return msg
  # Line 5: (empty)
  # Line 6: let result = greet("World")
  
  let ast = parse(code)
  discard vm.eval(ast)
  
  # The breakpoint on line 6 should have been hit
  doAssert 6 in hitLines, "Breakpoint on line 6 should have been hit"
  
  # Now test breakpoint INSIDE the function (line 3)
  hitLines = @[]
  breakpoints = [3].toHashSet
  
  discard vm.eval(ast)
  
  doAssert 3 in hitLines, "Breakpoint on line 3 (inside function) should have been hit"
  
  echo "  PASS: breakpoints inside functions"

# =============================================================================
# Test: Step Into Function
# =============================================================================

proc testStepIntoFunction() =
  echo "Testing step into function..."
  
  let vm = createVM()
  var executionOrder: seq[int] = @[]
  
  vm.onStatement = proc(line, col: int): bool =
    executionOrder.add(line)
    return true
  
  let code = """
proc double(n) =
  let result = n * 2
  return result

let x = double(5)
"""
  # Line 1: proc double(n) =
  # Line 2:   let result = n * 2
  # Line 3:   return result
  # Line 4: (empty)
  # Line 5: let x = double(5)
  
  let ast = parse(code)
  discard vm.eval(ast)
  
  # Execution order should be:
  # 1 (proc def), 5 (call), then inside function: 2, 3
  # The exact order depends on implementation but we should see lines 2 and 3
  doAssert 2 in executionOrder, "Line 2 (inside function) should be executed"
  doAssert 3 in executionOrder, "Line 3 (inside function) should be executed"
  doAssert 5 in executionOrder, "Line 5 (call site) should be executed"
  
  # Check that function body lines come after call site line in execution
  let callSiteIdx = executionOrder.find(5)
  let funcLine2Idx = executionOrder.find(2)
  let funcLine3Idx = executionOrder.find(3)
  
  if callSiteIdx >= 0 and funcLine2Idx >= 0:
    doAssert funcLine2Idx > callSiteIdx, "Function body should execute after call"
  
  echo "  PASS: step into function"

# =============================================================================
# Test: Nested Function Calls
# =============================================================================

proc testNestedFunctionCalls() =
  echo "Testing nested function calls..."
  
  let vm = createVM()
  var functionCalls: seq[string] = @[]
  
  vm.onEnterFunction = proc(name: string) =
    functionCalls.add(">" & name)
  
  vm.onExitFunction = proc(name: string) =
    functionCalls.add("<" & name)
  
  let code = """
proc inner(n) =
  return n * 2

proc middle(n) =
  return inner(n) + 1

proc outer(n) =
  return middle(n) + 10

let result = outer(5)
"""
  
  let ast = parse(code)
  discard vm.eval(ast)
  
  # Should see: >outer, >middle, >inner, <inner, <middle, <outer
  doAssert functionCalls.len == 6, "Expected 6 function events, got " & $functionCalls.len
  doAssert functionCalls[0] == ">outer"
  doAssert functionCalls[1] == ">middle"
  doAssert functionCalls[2] == ">inner"
  doAssert functionCalls[3] == "<inner"
  doAssert functionCalls[4] == "<middle"
  doAssert functionCalls[5] == "<outer"
  
  echo "  PASS: nested function calls"

# =============================================================================
# Test: Pause Execution at Breakpoint
# =============================================================================

proc testPauseAtBreakpoint() =
  echo "Testing pause at breakpoint..."
  
  let vm = createVM()
  var pausedAtLine = -1
  var breakpoints: HashSet[int] = [3].toHashSet
  
  # Hook that pauses at breakpoints
  vm.onStatement = proc(line, col: int): bool =
    if line in breakpoints:
      pausedAtLine = line
      return false  # Stop execution
    return true  # Continue
  
  let code = """
let a = 1
let b = 2
let c = 3
let d = 4
"""
  
  let ast = parse(code)
  discard vm.eval(ast)
  
  # Execution should have paused at line 3
  doAssert pausedAtLine == 3, "Should have paused at line 3, but paused at " & $pausedAtLine
  
  echo "  PASS: pause at breakpoint"

# =============================================================================
# Main
# =============================================================================

when isMainModule:
  echo "Running Nimmy debugger tests..."
  echo ""
  
  # Basic API tests (these should pass with current implementation)
  testBreakpointAPI()
  testStepModeAPI()
  testCallStackAPI()
  
  # VM hook tests (these require VM modifications)
  testVMStatementHook()
  testVMFunctionHooks()
  testBreakpointsInsideFunctions()
  testStepIntoFunction()
  testNestedFunctionCalls()
  testPauseAtBreakpoint()
  
  echo ""
  echo "All debugger tests passed!"
