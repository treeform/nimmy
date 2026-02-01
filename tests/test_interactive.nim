## test_interactive.nim
## Tests for the VM's interactive execution mode (runInteractive).
## 
## Interactive execution allows running code snippets in the context of
## the current VM state, useful for debugging REPLs and console evaluation.

import ../src/nimmy/[lexer, parser, vm, types]
import std/strutils

var testsPassed* = 0
var testsFailed* = 0

template test(name: string, body: untyped) =
  try:
    body
    testsPassed += 1
    echo "[PASS] ", name
  except AssertionDefect as e:
    testsFailed += 1
    echo "[FAIL] ", name, ": ", e.msg
  except Exception as e:
    testsFailed += 1
    echo "[FAIL] ", name, " (exception): ", e.msg

proc runInteractiveTests*(): tuple[passed: int, failed: int] =
  testsPassed = 0
  testsFailed = 0
  
  echo "\n=== Interactive Execution Tests ==="
  
  test "Simple expression evaluation":
    let myvm = newVM()
    let res = myvm.runInteractive("1 + 2")
    doAssert res.success
    doAssert res.value.kind == vkInt
    doAssert res.value.intVal == 3
  
  test "String expression":
    let myvm = newVM()
    let res = myvm.runInteractive("\"hello\"")
    doAssert res.success
    doAssert res.value.kind == vkString
    doAssert res.value.strVal == "hello"
  
  test "Variable lookup in current scope":
    # Load and run a script that defines a variable
    let code = """
let x = 42
let y = 10
"""
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    
    # Step through to execute the let statements
    myvm.step()  # let x = 42
    myvm.step()  # let y = 10
    
    # Now query the variable interactively
    let res = myvm.runInteractive("x")
    doAssert res.success
    doAssert res.value.kind == vkInt
    doAssert res.value.intVal == 42
  
  test "Expression with variables":
    let code = """
let a = 5
let b = 3
"""
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    myvm.step()  # let a = 5
    myvm.step()  # let b = 3
    
    let res = myvm.runInteractive("a + b")
    doAssert res.success
    doAssert res.value.kind == vkInt
    doAssert res.value.intVal == 8
  
  test "Interactive during mid-execution":
    let code = """
let x = 1
let y = 2
let z = 3
"""
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    
    # Execute first statement
    myvm.step()  # let x = 1
    doAssert myvm.currentLine == 2
    
    # Query interactively
    var res = myvm.runInteractive("x")
    doAssert res.success
    doAssert res.value.intVal == 1
    
    # Continue execution
    myvm.step()  # let y = 2
    
    # Query again
    res = myvm.runInteractive("x + y")
    doAssert res.success
    doAssert res.value.intVal == 3
    
    # VM should still be at the right place
    doAssert myvm.currentLine == 3
    doAssert not myvm.isFinished
  
  test "Call function defined in script":
    let code = """proc double(n) =
  return n * 2

let x = 5"""
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    
    # Execute the function definition and let
    myvm.step()  # proc double
    myvm.step()  # let x = 5
    
    # Call the function interactively
    let res = myvm.runInteractive("double(x)")
    doAssert res.success
    doAssert res.value.kind == vkInt
    doAssert res.value.intVal == 10
  
  test "Interactive echo":
    let myvm = newVM()
    let res = myvm.runInteractive("echo 1, 2, 3")
    doAssert res.success
    doAssert res.output.len == 1
    doAssert res.output[0] == "1 2 3"
  
  test "Interactive variable definition":
    let code = "let x = 10"
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    myvm.step()  # let x = 10
    
    # Define a new variable interactively
    var res = myvm.runInteractive("let y = x * 2")
    doAssert res.success
    
    # Query the new variable
    res = myvm.runInteractive("y")
    doAssert res.success
    doAssert res.value.intVal == 20
  
  test "Parse error handling":
    let myvm = newVM()
    let res = myvm.runInteractive("let x =")  # Incomplete
    doAssert not res.success
    doAssert res.error.len > 0
    doAssert "error" in res.error.toLowerAscii()
  
  test "Runtime error handling":
    let myvm = newVM()
    let res = myvm.runInteractive("undefined_var")  # Undefined variable
    doAssert not res.success
    doAssert res.error.len > 0
  
  test "Interactive does not affect VM execution state":
    let code = """
let a = 1
let b = 2
let c = 3
"""
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    
    # Execute first statement
    myvm.step()  # let a = 1
    let line1 = myvm.currentLine
    let depth1 = myvm.frames.len
    
    # Run interactive (should not change state)
    discard myvm.runInteractive("a + 100")
    
    # State should be unchanged
    doAssert myvm.currentLine == line1
    doAssert myvm.frames.len == depth1
    doAssert not myvm.isFinished
    
    # Can still continue execution
    myvm.step()  # let b = 2
    doAssert myvm.currentLine == 3
  
  test "Interactive inside function call":
    let code = """proc foo() =
  let local = 99
  return local

let r = foo()"""
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    
    # proc foo definition
    myvm.step()
    
    # Step into foo() call (stepInto behavior)
    myvm.stepInto()  # Enter function
    myvm.step()      # let local = 99
    
    # We're now inside the function - query local variable
    let res = myvm.runInteractive("local")
    doAssert res.success
    doAssert res.value.kind == vkInt
    doAssert res.value.intVal == 99
  
  test "Interactive error does not stop VM":
    let code = """let x = 10
let y = 20
let z = 30"""
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    
    # Execute first statement
    myvm.step()  # let x = 10
    doAssert myvm.currentLine == 2
    doAssert not myvm.isFinished
    
    # Cause an error in interactive mode
    let res = myvm.runInteractive("undefined_variable")
    doAssert not res.success
    doAssert res.error.len > 0
    
    # VM should still be in the same state - not stopped
    doAssert myvm.currentLine == 2
    doAssert not myvm.isFinished
    doAssert myvm.frames.len > 0
    
    # Should be able to continue stepping
    myvm.step()  # let y = 20
    doAssert myvm.currentLine == 3
    
    # Another interactive error
    let res2 = myvm.runInteractive("1 / 0")  # Division by zero
    # Even if this causes an error, VM continues
    
    # Can still finish execution
    myvm.step()  # let z = 30
    doAssert myvm.isFinished
  
  test "Interactive can set variables":
    let code = """let x = 10
var y = 0
echo y"""
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    
    # Execute let x = 10
    myvm.step()
    # Execute var y = 0
    myvm.step()
    
    # Query y before modification
    var res = myvm.runInteractive("y")
    doAssert res.success
    doAssert res.value.intVal == 0
    
    # Modify y via interactive mode
    res = myvm.runInteractive("y = 42")
    doAssert res.success
    
    # Query y after modification
    res = myvm.runInteractive("y")
    doAssert res.success
    doAssert res.value.intVal == 42
    
    # The modification persists when we continue execution
    myvm.step()  # echo y - should print 42
    doAssert myvm.output.len > 0
    doAssert myvm.output[^1] == "42"
  
  test "Interactive can define new variables":
    let code = "let x = 5"
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    
    # Execute let x = 5
    myvm.step()
    
    # Define a new variable interactively
    var res = myvm.runInteractive("let newVar = x * 10")
    doAssert res.success
    
    # The new variable should be accessible
    res = myvm.runInteractive("newVar")
    doAssert res.success
    doAssert res.value.intVal == 50
    
    # Can use both variables in expressions
    res = myvm.runInteractive("x + newVar")
    doAssert res.success
    doAssert res.value.intVal == 55
  
  test "Interactive function call with side effects":
    let code = """var counter = 0

proc increment() =
  counter = counter + 1
  return counter

let x = 1"""
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    
    # Execute var counter = 0
    myvm.step()
    # Execute proc increment
    myvm.step()
    # Execute let x = 1
    myvm.step()
    
    # Check counter is 0
    var res = myvm.runInteractive("counter")
    doAssert res.success
    doAssert res.value.intVal == 0
    
    # Call increment() interactively
    res = myvm.runInteractive("increment()")
    doAssert res.success
    doAssert res.value.intVal == 1
    
    # Counter should now be 1
    res = myvm.runInteractive("counter")
    doAssert res.success
    doAssert res.value.intVal == 1
    
    # Call again
    res = myvm.runInteractive("increment()")
    doAssert res.success
    doAssert res.value.intVal == 2
    
    # Counter should now be 2
    res = myvm.runInteractive("counter")
    doAssert res.success
    doAssert res.value.intVal == 2
  
  test "Multiple interactive errors don't accumulate":
    let code = "let x = 42"
    let myvm = newVM()
    let ast = parse(code)
    myvm.load(ast)
    myvm.step()
    
    # Cause multiple errors
    for i in 1..5:
      let res = myvm.runInteractive("undefined" & $i)
      doAssert not res.success
    
    # VM should still work fine
    let res = myvm.runInteractive("x")
    doAssert res.success
    doAssert res.value.intVal == 42
  
  test "Empty input":
    let myvm = newVM()
    let res = myvm.runInteractive("")
    doAssert res.success
    doAssert res.value.kind == vkNil
  
  test "Whitespace only input":
    let myvm = newVM()
    let res = myvm.runInteractive("   \n\t  ")
    doAssert res.success
  
  echo "\n--- Interactive Tests Summary ---"
  echo "Passed: ", testsPassed
  echo "Failed: ", testsFailed
  
  return (testsPassed, testsFailed)

when isMainModule:
  import std/strutils
  let (passed, failed) = runInteractiveTests()
  if failed > 0:
    quit(1)
