## test_security.nim
## Regression tests for sandbox hardening.
##
## These guard the exploits that let a hostile script escape the sandbox:
##   - out-of-bounds / type-confused element writes (memory corruption)
##   - unbounded native recursion (host C-stack overflow)
##   - unbounded execution / allocation (denial of service)
##   - a REPL assignment crash on non-identifier targets
##
## The key property is *containment*: a hostile script must surface as a
## catchable RuntimeError, never as an uncatchable Defect or a process crash,
## so an embedding host stays alive. Everything here runs in-process, so if a
## fix regresses to a Defect/segfault the test binary dies loudly.

import std/strutils
import ../src/nimmy
import ../src/nimmy/vm

var securityPassed* = 0
var securityFailed* = 0

proc check(name: string, cond: bool, detail = "") =
  if cond:
    echo "  PASS: " & name
    securityPassed += 1
  else:
    echo "  FAIL: " & name & (if detail.len > 0: "  (" & detail & ")" else: "")
    securityFailed += 1

proc expectContainedError(name, source, wanted: string,
                          maxSteps = 0, maxAllocations = 0) =
  ## The script must raise a catchable error whose message contains `wanted`.
  ## A missing error means the sandbox was bypassed; a non-matching message
  ## means it failed in an unexpected way.
  let nvm = newNimmyVM()
  nvm.vm.maxSteps = maxSteps
  nvm.vm.maxAllocations = maxAllocations
  var msg = ""
  var caught = false
  try:
    discard nvm.run(source)
  except CatchableError as e:
    caught = true
    msg = e.msg
  if not caught:
    check(name, false, "no error raised (sandbox bypass)")
  else:
    check(name, wanted in msg, "got: " & msg)

proc runSecurityTests*(): (int, int) =
  securityPassed = 0
  securityFailed = 0
  echo "Running security tests..."

  # -- Memory safety: every write path must be bounds- and type-checked. -------
  # Out-of-bounds write through a call-valued RHS (step() native path).
  expectContainedError(
    "oob write via call RHS",
    "var a = [1, 2, 3]\na[100000] = len(\"x\")\n",
    "out of bounds")
  # Negative index through the same path.
  expectContainedError(
    "negative index write via call RHS",
    "var a = [1, 2, 3]\na[-1] = len(\"x\")\n",
    "out of bounds")
  # String used as an array index (type confusion) via call-valued RHS.
  expectContainedError(
    "type-confused array write via call RHS",
    "var a = [1, 2, 3]\na[\"x\"] = len(\"x\")\n",
    "must be an integer")
  # Int used as a table key (type confusion) via call-valued RHS.
  expectContainedError(
    "type-confused table write via call RHS",
    "var t = {\"k\": 1}\nt[999] = len(\"x\")\n",
    "must be a string")
  # Same bugs reachable from expression context (evalExpr write path).
  expectContainedError(
    "oob write from expression-context call",
    "var a = [1, 2, 3]\nproc f() =\n  a[999999] = 7\n  return 0\necho f()\n",
    "out of bounds")
  expectContainedError(
    "type-confused write from expression-context call",
    "var a = [1, 2, 3]\nproc f() =\n  a[\"x\"] = 7\n  return 0\necho f()\n",
    "must be an integer")

  # -- Recursion depth: native recursion must not overflow the host stack. -----
  expectContainedError(
    "unbounded expression-context recursion",
    "proc f(n) =\n  return f(n) + 1\necho f(1)\n",
    "call depth exceeded")
  expectContainedError(
    "unbounded UFCS recursion",
    "proc f(x) =\n  return x.f\necho f(1)\n",
    "call depth exceeded")

  # -- Denial of service: an embedder can bound execution with maxSteps. -------
  expectContainedError(
    "infinite loop bounded by maxSteps",
    "while true:\n  var x = 1\n",
    "step count exceeded", maxSteps = 100_000)
  expectContainedError(
    "unbounded array growth bounded by maxSteps",
    "var a = [0]\nwhile true:\n  a = add(a, 0)\n",
    "step count exceeded", maxSteps = 100_000)

  # -- Allocation budget: bound memory, including super-linear growth. ----------
  # Exponential string growth (`s = s & s`) doubles memory per statement, so a
  # step budget cannot stop it before OOM; maxAllocations can.
  expectContainedError(
    "exponential string growth bounded by maxAllocations",
    "var s = \"x\"\nwhile true:\n  s = s & s\n",
    "Maximum allocation exceeded",
    maxSteps = 1_000_000, maxAllocations = 10_000_000)
  # Unbounded array growth is caught by the allocation budget too.
  expectContainedError(
    "array growth bounded by maxAllocations",
    "var a = [0]\nwhile true:\n  a = add(a, 0)\n",
    "Maximum allocation exceeded",
    maxSteps = 1_000_000, maxAllocations = 1_000_000)
  # Unbounded output is bounded as well.
  expectContainedError(
    "unbounded output bounded by maxAllocations",
    "var s = \"xxxxxxxxxx\"\nwhile true:\n  echo s\n  s = s & s\n",
    "Maximum allocation exceeded",
    maxSteps = 1_000_000, maxAllocations = 10_000_000)

  # A generous budget does not disturb an ordinary script, and the counter is
  # deterministic: the same script charges the same amount every run.
  block:
    proc allocOf(src: string): int =
      let nvm = newNimmyVM()
      discard nvm.run(src)
      allocationsUsed()
    let src = "var a = []\nfor i in 0 ..< 100:\n  a = add(a, i * i)\necho a.len\n"
    let a1 = allocOf(src)
    let a2 = allocOf(src)
    check("allocation accounting is deterministic", a1 == a2 and a1 > 0,
          "a1=" & $a1 & " a2=" & $a2)
  block:
    let nvm = newNimmyVM()
    nvm.vm.maxAllocations = 10_000_000
    var ok = false
    var got = ""
    try:
      got = nvm.run("var s = \"\"\nfor i in 0 ..< 50:\n  s = s & \"ab\"\necho s.len\n").strip()
      ok = got == "100"
    except CatchableError as e:
      got = "error: " & e.msg
    check("ordinary script runs within a generous allocation budget", ok, got)

  # -- Legitimate recursion must still work under the default depth cap. --------
  block:
    let nvm = newNimmyVM()
    var ok = false
    var got = ""
    try:
      got = nvm.run("proc fib(n) =\n  if n < 2:\n    return n\n  return fib(n - 1) + fib(n - 2)\necho fib(20)\n").strip()
      ok = got == "6765"
    except CatchableError as e:
      got = "error: " & e.msg
    check("legitimate recursion (fib 20) still works", ok, got)

  # -- REPL/debugger: assigning to an index target must not crash. --------------
  block:
    let nvm = newNimmyVM()
    discard nvm.vm.runInteractive("var a = [1, 2, 3]")
    let r = nvm.vm.runInteractive("a[0] = 9")
    let after = nvm.vm.runInteractive("a[0]")
    check("REPL index assignment does not crash",
          r.success and after.value != nil and after.value.kind == IntValue and
            after.value.intVal == 9,
          "success=" & $r.success)

  # -- Host stays alive: after all of the above, the VM is still usable. --------
  block:
    let nvm = newNimmyVM()
    let outp = nvm.run("echo 1 + 1\n").strip()
    check("host still usable after hostile scripts", outp == "2", outp)

  result = (securityPassed, securityFailed)

when isMainModule:
  let (p, f) = runSecurityTests()
  echo ""
  echo "  Security tests: " & $p & " passed, " & $f & " failed"
  if f > 0:
    quit(1)
