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

  # -- For loops iterate lazily: a huge range must not materialize. -------------
  # If the range were built into a seq up front it would OOM before any limit
  # could trip; lazy iteration means it simply runs until the step budget stops
  # it. (A regression here would hang or OOM this test, which is a loud signal.)
  expectContainedError(
    "huge range bounded by maxSteps, not materialized",
    "var last = 0\nfor i in 0 .. 1000000000:\n  last = i\n",
    "Maximum step count exceeded", maxSteps = 50_000)
  expectContainedError(
    "huge range in expression context is bounded",
    "proc f() =\n  var last = 0\n  for i in 0 .. 1000000000:\n    last = i\n" &
      "  return last\necho f()\n",
    "Maximum step count exceeded", maxSteps = 50_000)
  expectContainedError(
    "expression-context while is bounded",
    "proc g() =\n  while true:\n    var x = 1\n  return 0\necho g()\n",
    "Maximum step count exceeded", maxSteps = 50_000)
  block:
    # Lazy iteration must still be correct across ranges, strings and break.
    let nvm = newNimmyVM()
    var got = ""
    try:
      got = nvm.run(
        "var sum = 0\nfor i in 1 .. 100:\n  sum = sum + i\n" &
        "var n = 0\nfor c in \"hello\":\n  if c == \"l\":\n    break\n  n = n + 1\n" &
        "echo sum\necho n\n").strip()
    except CatchableError as e:
      got = "error: " & e.msg
    check("lazy for loops compute correct results", got == "5050\n2", got)

  # -- Rendering: cycles and deep nesting must not overflow the host stack. -----
  proc rendersWithoutCrash(name, source, wantSubstr: string) =
    let nvm = newNimmyVM()
    var got = ""
    var crashed = false
    try:
      got = nvm.run(source).strip()
    except CatchableError as e:
      got = "error: " & e.msg  # a catchable error is fine; a crash would abort
      crashed = true
    check(name, (not crashed) and wantSubstr in got, got)
  # A self-referential array/table renders as a cycle marker instead of
  # recursing forever on the C stack.
  rendersWithoutCrash("cyclic array renders without crashing",
    "var a = [1, 2]\na[0] = a\necho a\n", "...")
  rendersWithoutCrash("cyclic table renders without crashing",
    "var t = {\"k\": 1}\nt[\"k\"] = t\necho t\n", "...")
  # Very deep (but acyclic) nesting is capped by depth, not crashed.
  rendersWithoutCrash("deeply nested value renders without crashing",
    "var a = [0]\nfor i in 0 ..< 100000:\n  a = [a]\necho a\n", "...")
  block:
    # A shared (non-cyclic) value must still render fully — only true cycles
    # collapse to the marker.
    let nvm = newNimmyVM()
    var got = ""
    try:
      got = nvm.run("var x = [1]\necho [x, x]\n").strip()
    except CatchableError as e:
      got = "error: " & e.msg
    check("shared non-cyclic value renders fully", got == "[[1], [1]]", got)

  # -- Builtins and rendering charge the instruction budget. --------------------
  block:
    # A single statement that calls builtins charges more than one instruction,
    # proving native calls count (1 statement + echo + two len calls).
    let nvm = newNimmyVM()
    discard nvm.run("echo len(\"abc\") + len(\"de\")\n")
    check("builtins charge the instruction budget", nvm.vm.steps >= 4,
          "steps=" & $nvm.vm.steps)
  # A quadratic scan (contains in a loop) is bounded per comparison, not left to
  # run to completion.
  expectContainedError(
    "quadratic contains scan is bounded",
    "var a = []\nfor i in 0 ..< 5000:\n  a = add(a, i)\n" &
      "for j in 0 ..< 5000:\n  var found = contains(a, -1)\n",
    "Maximum step count exceeded", maxSteps = 200_000)
  # A loop of pure builtin calls is bounded even though a host set only maxSteps.
  expectContainedError(
    "loop of builtin calls is bounded by maxSteps",
    "var i = 0\nwhile i < 100000:\n  echo len(\"x\")\n  i = i + 1\n",
    "Maximum step count exceeded", maxSteps = 500)

  # -- Parser: deeply nested input raises a catchable error, never crashes. -----
  proc parseContained(name, source: string) =
    let nvm = newNimmyVM()
    var msg = ""
    var crashed = true
    try:
      discard nvm.run(source)
      crashed = false  # unexpected: should have been rejected
    except CatchableError as e:
      msg = e.msg
      crashed = false
    check(name, (not crashed) and "too deep" in msg, msg)
  block:
    var e = "1"
    for i in 0 ..< 5000: e = "1+(" & e & ")"  # deep right-nested arithmetic
    parseContained("deep expression is contained by the parser", "echo " & e & "\n")
  block:
    var p = "1"
    for i in 0 ..< 5000: p = "(" & p & ")"    # deep parentheses
    parseContained("deep parentheses are contained by the parser", "echo " & p & "\n")
  block:
    var a = "0"
    for i in 0 ..< 5000: a = "[" & a & "]"    # deep nested array literal
    parseContained("deep array literal is contained by the parser", "echo " & a & "\n")
  block:
    var src = ""
    var indent = ""
    for i in 0 ..< 400:                        # deep nested indented blocks
      src = src & indent & "if true:\n"
      indent = indent & "  "
    src = src & indent & "echo 1\n"
    parseContained("deep block nesting is contained by the parser", src)
  block:
    # Realistic nesting still parses and evaluates correctly.
    let nvm = newNimmyVM()
    var e = "1"
    for i in 0 ..< 40: e = "(1+" & e & ")"
    var got = ""
    try:
      got = nvm.run("echo " & e & "\n").strip()
    except CatchableError as ex:
      got = "error: " & ex.msg
    check("realistic nesting still evaluates", got == "41", got)

  # -- Safe by default: a freshly built VM needs no host configuration. --------
  block:
    let nvm = newNimmyVM()
    check("fresh VM has finite default limits",
          nvm.vm.maxSteps > 0 and nvm.vm.maxCallDepth > 0 and
            nvm.vm.maxAllocations > 0,
          "steps=" & $nvm.vm.maxSteps & " depth=" & $nvm.vm.maxCallDepth &
            " alloc=" & $nvm.vm.maxAllocations)
  block:
    # A memory bomb aborts on a default VM with no limits set by the host.
    # (Trips in ~28 doublings, so this is cheap.)
    let nvm = newNimmyVM()
    var msg = ""
    try:
      discard nvm.run("var s = \"x\"\nwhile true:\n  s = s & s\n")
    except CatchableError as e:
      msg = e.msg
    check("memory bomb contained by default (no host config)",
          "Maximum allocation exceeded" in msg, "got: " & msg)
  block:
    # Runaway recursion aborts on a default VM with no limits set by the host.
    let nvm = newNimmyVM()
    var msg = ""
    try:
      discard nvm.run("proc f(n) =\n  return f(n) + 1\necho f(1)\n")
    except CatchableError as e:
      msg = e.msg
    check("runaway recursion contained by default (no host config)",
          "Maximum call depth exceeded" in msg, "got: " & msg)

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
