## vm.nim
## Virtual Machine for the Nimmy scripting language
##
## Design: iterative execution with step() as the fundamental operation.
## - step() executes one statement and advances.
## - Blocks, loops and proc calls are frames on an explicit stack, never
##   native recursion, so a host can stop after any statement.
## - Expressions run on an explicit-stack evaluator that can pause when it
##   reaches a user proc call: the proc is pushed as a frame, runs step by
##   step, and its result is delivered back into the paused expression. A
##   proc therefore costs the same steps whether it is called as a statement,
##   in `let x = f()`, or inside `if f():`. There is no synchronous fallback.
## - All resource accounting lives on vm.budget; nothing is global.

import types
import utils
import parser
import std/[strformat, tables, strutils, sets]

const
  ## Default resource limits. A freshly constructed VM is hostile-safe out of
  ## the box — an infinite loop, runaway recursion, or memory bomb aborts with
  ## a catchable LimitError instead of hanging or OOM'ing the host. Hosts can
  ## raise any of these, or set it to 0 to disable that limit entirely.
  ##
  ## The values are deliberately generous: ordinary scripts never reach them,
  ## they only stop runaway ones. Multi-tenant hosts running many untrusted
  ## scripts should tighten them and add OS-level isolation as well.
  DefaultMaxSteps* = 10_000_000           ## ~seconds of interpreter work
  DefaultMaxCallDepth* = 256              ## script proc call depth
  DefaultMaxAllocations* = 256_000_000    ## ~256 MB of script-created data
  DefaultMaxInstructionsPerStep* = 0      ## per-step cap, 0 means unlimited

type
  FrameKind* = enum
    BlockFrame       ## Executing statements in a block
    ForLoopFrame     ## Executing a for loop
    WhileLoopFrame   ## Executing a while loop
    FunctionFrame    ## Inside a function call

  ForIterKind* = enum
    ForArrayIter     ## Iterate an array's backing elements by index
    ForStringIter    ## Iterate a string's characters by index
    ForRangeIter     ## Iterate an integer range lazily (never materialized)

  EvalTask = object
    ## One node on the evaluation stack: which children have been evaluated
    ## (phase) and their results so far.
    node: Node
    phase: int
    values: seq[Value]

  Evaluation* = ref object
    ## A resumable expression evaluation. When a user proc is called the
    ## evaluation is left waiting on the frame; the proc's return value is
    ## delivered by completing the call task and evaluation continues.
    root: Node
    tasks: seq[EvalTask]
    result: Value
    done: bool
    waiting: bool

  ExecutionFrame* = ref object
    kind*: FrameKind
    stmts: seq[Node]          ## Statements to execute
    stmtIndex: int            ## Current statement index
    scope: Scope              ## Scope for this frame
    # Statement in progress (a statement may span several steps when the
    # expressions it evaluates call user procs)
    evaluation: Evaluation    ## Expression currently being evaluated
    slotValues: seq[Value]    ## Expressions already evaluated for this statement
    slotCursor: int           ## Next slot to hand out while re-running the statement
    lastValue: Value          ## Value of the last expression statement (implicit return)
    # For loops (iterated lazily, so a huge range costs O(1) memory)
    forNode: Node             ## The for loop node
    forIterKind: ForIterKind  ## Which kind of iterable this frame walks
    forArray: seq[Value]      ## ForArrayIter: backing elements (aliased, not copied)
    forString: string         ## ForStringIter: backing string
    forIndex: int             ## ForArrayIter/ForStringIter position
    forRangeCur: int64        ## ForRangeIter current value
    forRangeEnd: int64        ## ForRangeIter inclusive end
    # While loops
    whileNode: Node           ## The while loop node
    # Functions
    funcName*: string         ## Function name (for debugging)
    returnToScope: Scope      ## Scope to restore after function returns

  VM* = ref object
    globalScope*: Scope
    currentScope*: Scope
    output*: seq[string]
    debugInfo*: DebugInfo
    budget*: Budget              ## Instruction and allocation accounting for this VM
    returnValue: Value           ## Value of a top-level return (see eval)
    lastValue*: Value            ## Value of the most recent expression statement
    # Execution state
    frames*: seq[ExecutionFrame] ## Stack of execution frames
    currentLine*: int            ## Current line number
    isFinished*: bool            ## Whether execution is complete
    # Debugging
    breakpoints*: HashSet[int]   ## Line numbers with breakpoints
    # Resource limits (defense against hostile / runaway scripts).
    # These default to finite safety nets (see DefaultMax* consts); set any to
    # 0 to disable that limit. The instruction and allocation limits live on
    # the budget and are exposed through maxSteps / maxAllocations /
    # maxInstructionsPerStep below.
    maxCallDepth*: int           ## Cap on nested script proc calls, 0 means unlimited
    functionDepth: int           ## Current number of function frames
    suspendRequested: bool       ## A native asked to end the step after it returns
    stepSuspended: bool          ## The current step ended inside a statement

## Limits

proc maxSteps*(vm: VM): int =
  ## Instruction budget per run, 0 means unlimited.
  vm.budget.instructionLimit

proc `maxSteps=`*(vm: VM, limit: int) =
  vm.budget.instructionLimit = limit

proc maxAllocations*(vm: VM): int =
  ## Allocation budget per run in units (approximate bytes), 0 means unlimited.
  vm.budget.allocationLimit

proc `maxAllocations=`*(vm: VM, limit: int) =
  vm.budget.allocationLimit = limit

proc maxInstructionsPerStep*(vm: VM): int =
  ## Cap on the instructions one step() may charge, 0 means unlimited. Keeps a
  ## single statement from doing unbounded work when a host counts steps.
  vm.budget.stepInstructionLimit

proc `maxInstructionsPerStep=`*(vm: VM, limit: int) =
  vm.budget.stepInstructionLimit = limit

proc steps*(vm: VM): int =
  ## Instructions charged in the current run (for host introspection).
  vm.budget.instructions

proc allocationsUsed*(vm: VM): int =
  ## Allocation units charged in the current run.
  vm.budget.allocations

proc charge(vm: VM, n = 1) =
  vm.budget.chargeInstructions(n)

proc chargeAllocation(vm: VM, units: int) =
  vm.budget.chargeAllocation(units)

proc suspend*(vm: VM) =
  ## For natives: ask the VM to end the current step() as soon as this native
  ## returns, even if the statement that called it is not finished. The
  ## statement resumes on the next step(). This lets a host make the action
  ## (the native call) the unit of time instead of the statement.
  vm.suspendRequested = true

proc suspended*(vm: VM): bool =
  ## Whether the last step() ended inside a statement (a proc call or a native
  ## suspend) rather than at a statement boundary.
  vm.stepSuspended

## Construction

proc newVM*(): VM =
  let global = newScope()
  let vm = VM(
    globalScope: global,
    currentScope: global,
    output: @[],
    debugInfo: DebugInfo(),
    budget: newBudget(DefaultMaxSteps, DefaultMaxAllocations,
                      DefaultMaxInstructionsPerStep),
    returnValue: nil,
    frames: @[],
    currentLine: 0,
    isFinished: true,
    breakpoints: initHashSet[int](),
    maxCallDepth: DefaultMaxCallDepth,
    functionDepth: 0
  )
  vm.globalScope.define(
    "echo",
    nativeProcValue("echo") do (args: seq[Value]) -> Value:
      var parts: seq[string] = @[]
      for arg in args:
        parts.add(valueString(arg, vm.budget))
      let line = parts.join(" ")
      vm.chargeAllocation(line.len + 1)  # bound unbounded output growth
      vm.output.add(line)
      nilValue(),
    sealed = true  # scripts cannot replace echo
  )
  return vm

proc error(vm: VM, msg: string, line, col: int) =
  var e = newException(RuntimeError, fmt"{msg} at line {line}, column {col}")
  e.line = line
  e.col = col
  raise e

proc limitError(vm: VM, msg: string, line, col: int) =
  var e = newException(LimitError, fmt"{msg} at line {line}, column {col}")
  e.line = line
  e.col = col
  raise e

proc defineChecked(vm: VM, name: string, value: Value, isConst = false) =
  ## Define a script-level binding, refusing to clobber a global the host sealed
  ## (builtins, host APIs). Only blocks redefinition in the scope that holds the
  ## sealed name, so a script can still use the name as a local or parameter.
  if vm.currentScope.isSealedHere(name):
    vm.error("Cannot redefine sealed global '" & name & "'", vm.currentLine, 0)
  vm.currentScope.define(name, value, isConst = isConst)

proc bodyStatements(node: Node): seq[Node] =
  if node.isNil:
    @[]
  elif node.kind == BlockNode:
    node.stmts
  else:
    @[node]

## Frames

proc currentFrame(vm: VM): ExecutionFrame =
  if vm.frames.len > 0:
    return vm.frames[^1]
  return nil

proc pushFrame(vm: VM, kind: FrameKind, stmts: seq[Node], scope: Scope) =
  let frame = ExecutionFrame(
    kind: kind,
    stmts: stmts,
    stmtIndex: 0,
    scope: scope
  )
  vm.frames.add(frame)

proc popFrame(vm: VM) =
  if vm.frames.len > 0:
    let frame = vm.frames[^1]
    vm.frames.setLen(vm.frames.len - 1)
    if frame.kind == FunctionFrame:
      dec vm.functionDepth
      vm.currentScope = frame.returnToScope

proc pushProcFrame(vm: VM, callee: Value, args: seq[Value], node: Node) =
  ## Start executing a user proc: its body becomes a frame that runs one
  ## statement per step. The caller's expression (if any) stays paused until
  ## the frame returns.
  if vm.maxCallDepth > 0 and vm.functionDepth >= vm.maxCallDepth:
    vm.limitError("Maximum call depth exceeded", node.line, node.col)
  var callArgs = args
  if callArgs.len != callee.procParams.len:
    if callee.procParams.len == 1 and callArgs.len > 1:
      callArgs = @[argsValue(callArgs)]
    else:
      vm.error("Expected " & $callee.procParams.len & " arguments, got " &
               $callArgs.len, node.line, node.col)
  let funcScope = newScope(callee.procClosure)
  for i, param in callee.procParams:
    funcScope.define(param, callArgs[i])
  let frame = ExecutionFrame(
    kind: FunctionFrame,
    stmts: bodyStatements(callee.procBody),
    stmtIndex: 0,
    scope: funcScope,
    funcName: callee.procName,
    returnToScope: vm.currentScope
  )
  vm.frames.add(frame)
  inc vm.functionDepth
  vm.currentScope = funcScope
  if frame.stmts.len > 0:
    vm.currentLine = frame.stmts[0].line

proc forCurrentValue(frame: ExecutionFrame): Value =
  ## The value the loop variable takes at the current position, produced on
  ## demand so ranges never materialize into a seq.
  case frame.forIterKind
  of ForArrayIter: frame.forArray[frame.forIndex]
  of ForStringIter: stringValue($frame.forString[frame.forIndex])
  of ForRangeIter: intValue(frame.forRangeCur)

proc forAdvance(frame: ExecutionFrame): bool =
  ## Advance to the next position; returns false when the iterable is
  ## exhausted. For ranges this never steps past the end, so it cannot
  ## overflow int64.
  case frame.forIterKind
  of ForArrayIter:
    frame.forIndex += 1
    frame.forIndex < frame.forArray.len
  of ForStringIter:
    frame.forIndex += 1
    frame.forIndex < frame.forString.len
  of ForRangeIter:
    if frame.forRangeCur >= frame.forRangeEnd:
      false
    else:
      frame.forRangeCur += 1
      true

## Operators
##
## Integer arithmetic wraps at 64 bits (two's complement) on every backend
## instead of raising an uncatchable OverflowDefect in the host: unsigned
## arithmetic on C (signed overflow is undefined there), BigInt.asIntN on JS
## (where an unchecked BigInt would just keep growing).

when defined(js):
  proc wrap64(x: int64): int64 {.importjs: "BigInt.asIntN(64, #)".}
  {.push overflowChecks: off.}
  proc wrapAdd(a, b: int64): int64 = wrap64(a + b)
  proc wrapSub(a, b: int64): int64 = wrap64(a - b)
  proc wrapMul(a, b: int64): int64 = wrap64(a * b)
  proc wrapNegate(x: int64): int64 = wrap64(0'i64 - x)
  {.pop.}
else:
  proc wrapAdd(a, b: int64): int64 = cast[int64](cast[uint64](a) + cast[uint64](b))
  proc wrapSub(a, b: int64): int64 = cast[int64](cast[uint64](a) - cast[uint64](b))
  proc wrapMul(a, b: int64): int64 = cast[int64](cast[uint64](a) * cast[uint64](b))
  proc wrapNegate(x: int64): int64 = cast[int64](0'u64 - cast[uint64](x))

proc applyBinaryOp(vm: VM, node: Node, left, right: Value): Value =
  case node.binOp
  of "+":
    if left.kind == IntValue and right.kind == IntValue:
      return intValue(wrapAdd(left.intVal, right.intVal))
    if left.kind in {IntValue, FloatValue} and right.kind in {IntValue, FloatValue}:
      return floatValue(toFloat(left) + toFloat(right))
    if left.kind == SetValue and right.kind == SetValue:
      var unionSet = left.setVal
      for elem in right.setVal:
        var found = false
        for existing in unionSet:
          if equals(existing, elem, vm.budget):
            found = true
            break
        if not found:
          unionSet.add(elem)
      vm.chargeAllocation(unionSet.len * 8 + 8)
      return setValue(unionSet)
    vm.error("Cannot add " & typeName(left) & " and " & typeName(right), node.line, node.col)

  of "-":
    if left.kind == IntValue and right.kind == IntValue:
      return intValue(wrapSub(left.intVal, right.intVal))
    if left.kind in {IntValue, FloatValue} and right.kind in {IntValue, FloatValue}:
      return floatValue(toFloat(left) - toFloat(right))
    if left.kind == SetValue and right.kind == SetValue:
      var diffSet: seq[Value] = @[]
      for elem in left.setVal:
        var found = false
        for other in right.setVal:
          if equals(elem, other, vm.budget):
            found = true
            break
        if not found:
          diffSet.add(elem)
      vm.chargeAllocation(diffSet.len * 8 + 8)
      return setValue(diffSet)
    vm.error("Cannot subtract " & typeName(right) & " from " & typeName(left), node.line, node.col)

  of "*":
    if left.kind == IntValue and right.kind == IntValue:
      return intValue(wrapMul(left.intVal, right.intVal))
    if left.kind in {IntValue, FloatValue} and right.kind in {IntValue, FloatValue}:
      return floatValue(toFloat(left) * toFloat(right))
    if left.kind == SetValue and right.kind == SetValue:
      var interSet: seq[Value] = @[]
      for elem in left.setVal:
        for other in right.setVal:
          if equals(elem, other, vm.budget):
            interSet.add(elem)
            break
      vm.chargeAllocation(interSet.len * 8 + 8)
      return setValue(interSet)
    vm.error("Cannot multiply " & typeName(left) & " and " & typeName(right), node.line, node.col)

  of "/":
    when defined(nimmyNoFloats):
      vm.error("Float division is disabled in this build, use div", node.line, node.col)
    if left.kind in {IntValue, FloatValue} and right.kind in {IntValue, FloatValue}:
      let r = toFloat(right)
      if r == 0:
        vm.error("Division by zero", node.line, node.col)
      return floatValue(toFloat(left) / r)
    vm.error("Cannot divide " & typeName(left) & " by " & typeName(right), node.line, node.col)

  of "div":
    if left.kind == IntValue and right.kind == IntValue:
      if right.intVal == 0:
        vm.error("Division by zero", node.line, node.col)
      if right.intVal == -1:
        return intValue(wrapNegate(left.intVal))  # low(int64) div -1 would trap
      return intValue(left.intVal div right.intVal)
    vm.error("div requires integers", node.line, node.col)

  of "mod", "%":
    if left.kind == IntValue and right.kind == IntValue:
      if right.intVal == 0:
        vm.error("Modulo by zero", node.line, node.col)
      if right.intVal == -1:
        return intValue(0)  # low(int64) mod -1 would trap
      return intValue(left.intVal mod right.intVal)
    vm.error("mod requires integers", node.line, node.col)

  of "&":
    let joined = valueString(left, vm.budget) & valueString(right, vm.budget)
    vm.chargeAllocation(joined.len + 1)
    return stringValue(joined)

  of "==":
    return boolValue(equals(left, right, vm.budget))

  of "!=":
    return boolValue(not equals(left, right, vm.budget))

  of "<":
    return boolValue(compare(left, right) < 0)

  of ">":
    return boolValue(compare(left, right) > 0)

  of "<=":
    return boolValue(compare(left, right) <= 0)

  of ">=":
    return boolValue(compare(left, right) >= 0)

  of "in":
    case right.kind
    of ArrayValue:
      for elem in right.arrayVal:
        if equals(left, elem, vm.budget):
          return boolValue(true)
      return boolValue(false)
    of StringValue:
      if left.kind != StringValue:
        vm.error("'in' requires string on left for string search", node.line, node.col)
      vm.charge(right.strVal.len)  # substring scan is O(n)
      return boolValue(left.strVal in right.strVal)
    of TableValue:
      if left.kind != StringValue:
        vm.error("'in' requires string key for table", node.line, node.col)
      return boolValue(right.tableVal.hasKey(left.strVal))
    of SetValue:
      return boolValue(setContains(right, left, vm.budget))
    else:
      vm.error("'in' not supported for " & typeName(right), node.line, node.col)

  else:
    vm.error("Unknown operator: " & node.binOp, node.line, node.col)

proc applyUnaryOp(vm: VM, node: Node, operand: Value): Value =
  case node.unOp
  of "-":
    if operand.kind == IntValue:
      return intValue(wrapNegate(operand.intVal))
    if operand.kind == FloatValue:
      return floatValue(-operand.floatVal)
    vm.error("Cannot negate " & typeName(operand), node.line, node.col)
  of "not":
    return boolValue(not isTruthy(operand))
  of "$":
    let rendered = valueString(operand, vm.budget)
    vm.chargeAllocation(rendered.len + 1)
    return stringValue(rendered)
  else:
    vm.error("Unknown unary operator: " & node.unOp, node.line, node.col)

proc applyIndex(vm: VM, node: Node, obj, index: Value): Value =
  if obj.kind == ArrayValue:
    if index.kind != IntValue:
      vm.error("Array index must be an integer", node.line, node.col)
    let i = index.intVal
    if i < 0 or i >= obj.arrayVal.len:
      vm.error(fmt"Array index {i} out of bounds", node.line, node.col)
    return obj.arrayVal[i]

  if obj.kind == StringValue:
    if index.kind != IntValue:
      vm.error("String index must be an integer", node.line, node.col)
    let i = index.intVal
    if i < 0 or i >= obj.strVal.len:
      vm.error(fmt"String index {i} out of bounds", node.line, node.col)
    vm.chargeAllocation(2)
    return stringValue($obj.strVal[i])

  if obj.kind == TableValue:
    if index.kind != StringValue:
      vm.error("Table key must be a string", node.line, node.col)
    if obj.tableVal.hasKey(index.strVal):
      return obj.tableVal[index.strVal]
    return nilValue()

  vm.error(fmt"Cannot index {typeName(obj)}", node.line, node.col)

proc assignIndex(vm: VM, target: Node, obj, index, value: Value) =
  ## Element write with full bounds and type checking. Every write path
  ## routes through here or assignField so none can bypass the checks
  ## (prevents out-of-bounds and type-confused writes, which are
  ## memory-unsafe under -d:danger and abort the host otherwise).
  if obj.kind == ArrayValue:
    if index.kind != IntValue:
      vm.error("Array index must be an integer", target.line, target.col)
    let i = index.intVal
    if i < 0 or i >= obj.arrayVal.len:
      vm.error(fmt"Array index {i} out of bounds", target.line, target.col)
    obj.arrayVal[i] = value
  elif obj.kind == TableValue:
    if index.kind != StringValue:
      vm.error("Table key must be a string", target.line, target.col)
    if not obj.tableVal.hasKey(index.strVal):
      vm.chargeAllocation(index.strVal.len + 16)
    obj.tableVal[index.strVal] = value
  else:
    vm.error(fmt"Cannot index assign {typeName(obj)}", target.line, target.col)

proc assignField(vm: VM, target: Node, obj, value: Value) =
  if obj.kind == ObjectValue:
    obj.objFields[target.dotField] = value
  else:
    vm.error(fmt"Cannot assign field of {typeName(obj)}", target.line, target.col)

proc assignName(vm: VM, target: Node, value: Value) =
  let name = target.name
  if vm.currentScope.isSealed(name):
    vm.error(fmt"Cannot assign to sealed global '{name}'", target.line, target.col)
  if vm.currentScope.isConstant(name):
    vm.error(fmt"Cannot assign to constant '{name}'", target.line, target.col)
  if not vm.currentScope.assign(name, value):
    vm.error(fmt"Undefined variable '{name}'", target.line, target.col)

## Expression evaluation
##
## An Evaluation is a stack of EvalTasks. The top task asks for its next
## child (nextChild); when it has none left, finishTask turns the collected
## child values into the task's value, which is handed to the parent task.
## A user proc call pushes a FunctionFrame instead of producing a value and
## leaves the evaluation waiting; the return value is delivered later.

proc nextChild(task: EvalTask): Node =
  ## The next child node to evaluate for `task`, or nil when all are done.
  let node = task.node
  case node.kind
  of BinaryOpNode:
    if task.phase == 0:
      return node.binLeft
    if task.phase == 1:
      # Short-circuit: the right side is not evaluated at all.
      if node.binOp == "and" and not isTruthy(task.values[0]):
        return nil
      if node.binOp == "or" and isTruthy(task.values[0]):
        return nil
      return node.binRight
    nil
  of UnaryOpNode:
    if task.phase == 0: node.unOperand else: nil
  of IndexNode:
    case task.phase
    of 0: node.indexee
    of 1: node.index
    else: nil
  of DotNode:
    if task.phase == 0: node.dotLeft else: nil
  of CallNode:
    # a.b(args): evaluate a, then args. f(args): args only. (expr)(args):
    # the callee expression, then args.
    let calleeChildren = if node.callee.kind == IdentNode: 0 else: 1
    if task.phase < calleeChildren:
      if node.callee.kind == DotNode:
        return node.callee.dotLeft
      return node.callee
    let argIndex = task.phase - calleeChildren
    if argIndex < node.args.len: node.args[argIndex] else: nil
  of ArrayNode:
    if task.phase < node.arrayElems.len: node.arrayElems[task.phase] else: nil
  of SetNode:
    if task.phase < node.setElems.len: node.setElems[task.phase] else: nil
  of TableNode:
    let i = task.phase
    if i < node.tableKeys.len * 2:
      if i mod 2 == 0: node.tableKeys[i div 2] else: node.tableVals[i div 2]
    else:
      nil
  of RangeNode:
    case task.phase
    of 0: node.rangeStart
    of 1: node.rangeEnd
    else: nil
  else:
    nil

proc invoke(vm: VM, ev: Evaluation, callee: Value, args: seq[Value],
            node: Node): Value =
  ## Call `callee` with evaluated `args`. Natives return immediately; a user
  ## proc becomes a frame and leaves `ev` waiting for its result.
  case callee.kind
  of NativeProcValue:
    vm.charge()
    return callee.nativeProc(args)
  of TypeValue:
    vm.chargeAllocation(8)
    let obj = objectValue(callee.typeNameVal)
    for i, arg in args:
      if i < callee.typeFields.len:
        obj.objFields[callee.typeFields[i]] = arg
    return obj
  of ProcValue:
    ev.waiting = true
    vm.pushProcFrame(callee, args, node)
    return nil
  else:
    vm.error("Cannot call " & typeName(callee), node.line, node.col)

proc finishCall(vm: VM, ev: Evaluation, task: EvalTask): Value =
  let node = task.node
  var callee: Value
  var args: seq[Value]
  case node.callee.kind
  of IdentNode:
    callee = vm.currentScope.lookup(node.callee.name)
    if callee.isNil:
      vm.error("Unknown function: " & node.callee.name, node.line, node.col)
    args = task.values
  of DotNode:
    # UFCS: obj.method(args) — a proc stored in the object's field, else a
    # proc in scope called with obj as the first argument.
    let receiver = task.values[0]
    args = task.values[1 .. ^1]
    let methodName = node.callee.dotField
    if receiver.kind == ObjectValue and receiver.objFields.hasKey(methodName):
      callee = receiver.objFields[methodName]
    else:
      callee = vm.currentScope.lookup(methodName)
      if callee.isNil:
        vm.error("Unknown function: " & methodName, node.line, node.col)
      args = receiver & args
  else:
    callee = task.values[0]
    args = task.values[1 .. ^1]
  vm.invoke(ev, callee, args, node)

proc finishDot(vm: VM, ev: Evaluation, node: Node, obj: Value): Value =
  if obj.kind == ObjectValue:
    if obj.objFields.hasKey(node.dotField):
      return obj.objFields[node.dotField]
    # Don't error yet - try UFCS below

  if obj.kind == ArrayValue:
    if node.dotField == "len":
      return intValue(obj.arrayVal.len)

  if obj.kind == StringValue:
    if node.dotField == "len":
      return intValue(obj.strVal.len)

  if obj.kind == SetValue:
    if node.dotField == "len" or node.dotField == "card":
      return intValue(obj.setVal.len)

  if obj.kind == TableValue:
    if node.dotField == "len":
      return intValue(obj.tableVal.len)

  # UFCS without parens: obj.f calls f(obj)
  let funcVal = vm.currentScope.lookup(node.dotField)
  if funcVal != nil:
    if funcVal.kind == NativeProcValue:
      vm.charge()
      return funcVal.nativeProc(@[obj])
    elif funcVal.kind == ProcValue:
      if funcVal.procParams.len != 1:
        vm.error("UFCS call requires function with 1 parameter", node.line, node.col)
      ev.waiting = true
      vm.pushProcFrame(funcVal, @[obj], node)
      return nil

  if obj.kind == ObjectValue:
    vm.error("Object has no field '" & node.dotField & "'", node.line, node.col)
  else:
    vm.error("Cannot access field of " & typeName(obj), node.line, node.col)

proc finishTask(vm: VM, ev: Evaluation): Value =
  ## Produce the value of the top task from its evaluated children. Returns
  ## nil with ev.waiting set when a user proc frame was pushed instead.
  let task = ev.tasks[^1]
  let node = task.node
  case node.kind
  of IntLitNode:
    intValue(node.intVal)
  of FloatLitNode:
    floatValue(node.floatVal)
  of StrLitNode:
    vm.chargeAllocation(node.strVal.len + 1)
    stringValue(node.strVal)
  of BoolLitNode:
    boolValue(node.boolVal)
  of NilLitNode, EmptyNode:
    nilValue()
  of IdentNode:
    let value = vm.currentScope.lookup(node.name)
    if value.isNil:
      vm.error(fmt"Undefined variable '{node.name}'", node.line, node.col)
    value
  of BinaryOpNode:
    vm.charge()
    if node.binOp == "and" or node.binOp == "or":
      if task.values.len == 1:
        # Short-circuited on the left operand.
        boolValue(node.binOp == "or")
      else:
        boolValue(isTruthy(task.values[1]))
    else:
      vm.applyBinaryOp(node, task.values[0], task.values[1])
  of UnaryOpNode:
    vm.charge()
    vm.applyUnaryOp(node, task.values[0])
  of IndexNode:
    vm.charge()
    vm.applyIndex(node, task.values[0], task.values[1])
  of DotNode:
    vm.charge()
    vm.finishDot(ev, node, task.values[0])
  of CallNode:
    vm.finishCall(ev, task)
  of ArrayNode:
    vm.charge()
    vm.chargeAllocation(task.values.len * 8 + 8)
    arrayValue(task.values)
  of SetNode:
    vm.charge()
    var elems: seq[Value] = @[]
    for val in task.values:
      var found = false
      for existing in elems:
        if equals(existing, val, vm.budget):
          found = true
          break
      if not found:
        elems.add(val)
    vm.chargeAllocation(elems.len * 8 + 8)
    setValue(elems)
  of TableNode:
    vm.charge()
    vm.chargeAllocation(8)
    let table = tableValue()
    var i = 0
    while i < task.values.len:
      let key = task.values[i]
      let val = task.values[i + 1]
      if key.kind != StringValue:
        vm.error("Table key must be a string", node.line, node.col)
      vm.chargeAllocation(key.strVal.len + 16)
      table.tableVal[key.strVal] = val
      i += 2
    table
  of RangeNode:
    let startVal = task.values[0]
    let endVal = task.values[1]
    if startVal.kind != IntValue or endVal.kind != IntValue:
      vm.error("Range bounds must be integers", node.line, node.col)
    rangeValue(startVal.intVal, endVal.intVal, node.rangeInclusive)
  else:
    vm.error("Expected an expression", node.line, node.col)
    nil

proc completeTask(ev: Evaluation, value: Value) =
  ## Pop the top task and hand its value to the parent (or finish).
  ev.tasks.setLen(ev.tasks.len - 1)
  if ev.tasks.len == 0:
    ev.result = value
    ev.done = true
  else:
    ev.tasks[^1].values.add(value)
    ev.tasks[^1].phase += 1

proc deliver(ev: Evaluation, value: Value) =
  ## A user proc the evaluation was waiting on has returned `value`.
  ev.waiting = false
  ev.completeTask(value)

proc runEvaluation(vm: VM, ev: Evaluation) =
  ## Evaluate until done, or until a user proc frame is pushed (ev.waiting),
  ## or until a native asked to suspend the step.
  while not ev.done and not ev.waiting and not vm.suspendRequested:
    let child = nextChild(ev.tasks[^1])
    if child != nil:
      ev.tasks.add(EvalTask(node: child))
      continue
    let value = vm.finishTask(ev)
    if ev.waiting:
      return
    ev.completeTask(value)

proc evalSlot(vm: VM, frame: ExecutionFrame, node: Node): Value =
  ## Value of the next expression of the statement being executed in `frame`.
  ## Expressions a statement already finished are replayed from slotValues,
  ## so re-running the statement after a pause never evaluates them twice.
  ## Returns nil and sets vm.stepSuspended when the step must end here.
  if frame.slotCursor < frame.slotValues.len:
    result = frame.slotValues[frame.slotCursor]
    inc frame.slotCursor
    return
  if node.isNil:
    frame.slotValues.add(nilValue())
    inc frame.slotCursor
    return nilValue()
  if frame.evaluation.isNil:
    frame.evaluation = Evaluation(root: node, tasks: @[EvalTask(node: node)])
  let ev = frame.evaluation
  vm.runEvaluation(ev)
  if ev.done:
    frame.evaluation = nil
    frame.slotValues.add(ev.result)
    inc frame.slotCursor
    if vm.suspendRequested:
      vm.suspendRequested = false
      vm.stepSuspended = true
      return nil
    return ev.result
  # Waiting on a proc frame, or a native asked to suspend: resume next step.
  vm.suspendRequested = false
  vm.stepSuspended = true
  return nil

## Statement execution

proc advanceFrame(vm: VM)
proc execStatement(vm: VM, frame: ExecutionFrame, stmt: Node)

proc updateLine(vm: VM) =
  let frame = vm.currentFrame
  if frame == nil:
    vm.isFinished = true
    return

  if frame.stmtIndex < frame.stmts.len:
    vm.currentLine = frame.stmts[frame.stmtIndex].line
  else:
    # Frame statements are exhausted, advance the frame
    vm.advanceFrame()

proc advanceStatement(frame: ExecutionFrame) =
  ## Move past the current statement and forget its evaluation state.
  frame.stmtIndex += 1
  frame.slotValues.setLen(0)
  frame.slotCursor = 0
  frame.evaluation = nil

proc finishStatement(vm: VM, frame: ExecutionFrame) =
  frame.advanceStatement()
  vm.updateLine()

proc resumeFrame(vm: VM) =
  ## Continue the current frame within this step: re-run the statement that
  ## was paused on a proc call (it replays its finished expressions and picks
  ## up where it stopped), or re-check a while condition at loop-back.
  let frame = vm.currentFrame
  if frame == nil:
    vm.isFinished = true
    return
  vm.currentScope = frame.scope
  if frame.stmtIndex >= frame.stmts.len:
    vm.advanceFrame()
  else:
    vm.execStatement(frame, frame.stmts[frame.stmtIndex])

proc deliverReturn(vm: VM, value: Value) =
  ## A function frame was popped with `value`; hand it to the caller's paused
  ## expression and let the caller's statement continue in this step.
  vm.lastValue = value
  let caller = vm.currentFrame
  if caller == nil:
    vm.returnValue = value
    vm.isFinished = true
    return
  if caller.evaluation != nil and caller.evaluation.waiting:
    caller.evaluation.deliver(value)
    vm.resumeFrame()
  else:
    vm.currentScope = caller.scope
    vm.updateLine()

proc returnFromProc(vm: VM, value: Value) =
  ## Unwind to the innermost function frame and return `value` from it. A
  ## `return` outside any proc ends the program with that value.
  var popped = false
  while vm.frames.len > 0:
    let f = vm.currentFrame
    vm.popFrame()
    if f.kind == FunctionFrame:
      popped = true
      break
  if not popped:
    vm.returnValue = value
    vm.lastValue = value
    vm.isFinished = true
    return
  vm.deliverReturn(value)

proc advanceFrame(vm: VM) =
  ## Called when a frame's statements are exhausted: loop back or pop it.
  if vm.frames.len == 0:
    vm.isFinished = true
    return

  let frame = vm.currentFrame

  case frame.kind
  of ForLoopFrame:
    if not frame.forAdvance():
      vm.popFrame()
      if vm.frames.len == 0:
        vm.isFinished = true
      else:
        # Note: stmtIndex was already incremented when we set up the loop
        vm.updateLine()
    else:
      # Create new scope for each iteration (important for closures)
      frame.stmtIndex = 0
      frame.slotValues.setLen(0)
      frame.slotCursor = 0
      frame.evaluation = nil
      let parentScope = frame.scope.parent
      let iterScope = newScope(parentScope)
      iterScope.define(frame.forNode.forVar, frame.forCurrentValue())
      frame.scope = iterScope
      vm.currentScope = iterScope
      vm.updateLine()

  of WhileLoopFrame:
    # Re-check the condition. It may call a user proc, in which case the loop
    # frame waits and the check completes when that proc returns.
    vm.currentScope = frame.scope
    frame.slotCursor = 0
    let cond = vm.evalSlot(frame, frame.whileNode.whileCond)
    if vm.stepSuspended:
      return
    frame.slotValues.setLen(0)
    frame.slotCursor = 0
    frame.evaluation = nil
    if isTruthy(cond):
      frame.stmtIndex = 0
      vm.updateLine()
    else:
      vm.popFrame()
      if vm.frames.len == 0:
        vm.isFinished = true
      else:
        # Note: stmtIndex was already incremented when we set up the loop
        vm.updateLine()

  of FunctionFrame:
    # Fell off the end of the body: the value of a trailing expression
    # statement is the implicit return value (`proc double(x) = x * 2`).
    let returnVal = if frame.lastValue != nil: frame.lastValue else: nilValue()
    vm.popFrame()
    vm.deliverReturn(returnVal)

  of BlockFrame:
    let blockValue = frame.lastValue
    vm.popFrame()
    if vm.frames.len == 0:
      vm.isFinished = true
    else:
      # An `if` that is the last statement of a proc yields its branch's
      # trailing expression, so `if c: 1 else: 2` works as an implicit return.
      vm.currentFrame.lastValue = blockValue
      vm.updateLine()

proc execStatement(vm: VM, frame: ExecutionFrame, stmt: Node) =
  ## Execute (or resume) one statement. Each expression the statement needs
  ## is a slot; a slot whose evaluation pauses on a proc call makes the whole
  ## procedure return early, and the statement is re-run when the proc comes
  ## back, replaying the slots it already finished.
  frame.slotCursor = 0

  template slot(node: Node): Value =
    let slotValue = vm.evalSlot(frame, node)
    if vm.stepSuspended:
      return
    slotValue

  case stmt.kind
  of LetStmtNode, VarStmtNode:
    let value = slot(stmt.varValue)
    vm.defineChecked(stmt.varName, value, isConst = stmt.kind == LetStmtNode)
    frame.lastValue = nil
    vm.finishStatement(frame)

  of AssignNode:
    let value = slot(stmt.assignValue)
    let target = stmt.assignTarget
    case target.kind
    of IdentNode:
      vm.assignName(target, value)
    of IndexNode:
      let obj = slot(target.indexee)
      let index = slot(target.index)
      vm.assignIndex(target, obj, index, value)
    of DotNode:
      let obj = slot(target.dotLeft)
      vm.assignField(target, obj, value)
    else:
      vm.error("Invalid assignment target", target.line, target.col)
    frame.lastValue = value
    vm.lastValue = value
    vm.finishStatement(frame)

  of ProcDefNode:
    let procVal = procValue(stmt.procName, stmt.procParams, stmt.procBody, vm.currentScope)
    vm.defineChecked(stmt.procName, procVal)
    frame.lastValue = nil
    vm.finishStatement(frame)

  of TypeDefNode:
    var fields: seq[string] = @[]
    if stmt.typeBody.kind == ObjectDefNode:
      for field in stmt.typeBody.objectFields:
        fields.add(field.fieldName)
    vm.defineChecked(stmt.typeName, typeValue(stmt.typeName, fields))
    frame.lastValue = nil
    vm.finishStatement(frame)

  of IfStmtNode:
    var body: Node = nil
    if isTruthy(slot(stmt.ifCond)):
      body = stmt.ifBody
    else:
      for branch in stmt.elifBranches:
        if isTruthy(slot(branch.elifCond)):
          body = branch.elifBody
          break
      if body.isNil and stmt.elseBranch != nil:
        if stmt.elseBranch.kind == ElseBranchNode:
          body = stmt.elseBranch.elseBody
        else:
          body = stmt.elseBranch
    frame.lastValue = nil
    frame.advanceStatement()
    let bodyStmts = bodyStatements(body)
    if bodyStmts.len > 0:
      let blockScope = newScope(vm.currentScope)
      vm.currentScope = blockScope
      vm.pushFrame(BlockFrame, bodyStmts, blockScope)
    vm.updateLine()

  of ForStmtNode:
    let iter = slot(stmt.forIter)
    let bodyStmts = bodyStatements(stmt.forBody)

    # Build a lazy loop frame. Ranges are not materialized, so `for i in
    # 0 .. 100_000_000` costs O(1) memory here; each iteration then charges the
    # step budget, keeping the loop bounded.
    var loopFrame: ExecutionFrame = nil
    case iter.kind
    of RangeValue:
      let s = iter.rangeStart
      let e = if iter.rangeInclusive: iter.rangeEnd else: iter.rangeEnd - 1
      if s <= e:
        loopFrame = ExecutionFrame(
          kind: ForLoopFrame, stmts: bodyStmts, stmtIndex: 0,
          forNode: stmt, forIterKind: ForRangeIter,
          forRangeCur: s, forRangeEnd: e)
    of ArrayValue:
      if iter.arrayVal.len > 0:
        loopFrame = ExecutionFrame(
          kind: ForLoopFrame, stmts: bodyStmts, stmtIndex: 0,
          forNode: stmt, forIterKind: ForArrayIter,
          forArray: iter.arrayVal, forIndex: 0)
    of StringValue:
      if iter.strVal.len > 0:
        loopFrame = ExecutionFrame(
          kind: ForLoopFrame, stmts: bodyStmts, stmtIndex: 0,
          forNode: stmt, forIterKind: ForStringIter,
          forString: iter.strVal, forIndex: 0)
    else:
      vm.error("Cannot iterate over " & typeName(iter), stmt.line, stmt.col)

    frame.lastValue = nil
    frame.advanceStatement()
    if loopFrame != nil:
      let loopScope = newScope(vm.currentScope)
      vm.currentScope = loopScope
      loopFrame.scope = loopScope
      loopScope.define(stmt.forVar, loopFrame.forCurrentValue())
      vm.frames.add(loopFrame)
    vm.updateLine()

  of WhileStmtNode:
    let cond = slot(stmt.whileCond)
    frame.lastValue = nil
    frame.advanceStatement()  # Advance past while statement before entering loop
    if isTruthy(cond):
      let loopScope = newScope(vm.currentScope)
      vm.currentScope = loopScope
      let loopFrame = ExecutionFrame(
        kind: WhileLoopFrame,
        stmts: bodyStatements(stmt.whileBody),
        stmtIndex: 0,
        scope: loopScope,
        whileNode: stmt
      )
      vm.frames.add(loopFrame)
    vm.updateLine()

  of ReturnStmtNode:
    var value: Value
    if stmt.returnValue != nil:
      value = slot(stmt.returnValue)
    else:
      value = nilValue()
    vm.returnFromProc(value)

  of BreakStmtNode:
    # Pop frames until we exit the loop
    while vm.frames.len > 0:
      let f = vm.currentFrame
      vm.popFrame()
      if f.kind in {ForLoopFrame, WhileLoopFrame}:
        break

    if vm.frames.len == 0:
      vm.isFinished = true
    else:
      # Note: stmtIndex was already incremented when we set up the loop
      vm.currentScope = vm.currentFrame.scope
      vm.updateLine()

  of ContinueStmtNode:
    # Pop frames until we reach the loop
    while vm.frames.len > 0:
      let f = vm.currentFrame
      if f.kind in {ForLoopFrame, WhileLoopFrame}:
        f.stmtIndex = f.stmts.len  # Will trigger next iteration check
        break
      vm.popFrame()
    vm.updateLine()

  of BlockNode:
    frame.lastValue = nil
    frame.advanceStatement()
    if stmt.stmts.len > 0:
      let blockScope = newScope(vm.currentScope)
      vm.currentScope = blockScope
      vm.pushFrame(BlockFrame, stmt.stmts, blockScope)
    vm.updateLine()

  of EmptyNode:
    frame.lastValue = nil
    vm.finishStatement(frame)

  else:
    # Expression statement (a call, `discard expr`, or a trailing value)
    let value = slot(stmt)
    frame.lastValue = value
    vm.lastValue = value
    vm.finishStatement(frame)

## Stepping API

proc load*(vm: VM, ast: Node) =
  ## Load an AST for step-by-step execution.
  vm.frames = @[]
  vm.isFinished = false
  vm.returnValue = nil
  vm.lastValue = nil
  vm.currentScope = vm.globalScope
  vm.functionDepth = 0
  vm.suspendRequested = false
  vm.stepSuspended = false
  vm.budget.reset()

  var stmts: seq[Node] = @[]
  if ast.kind == ProgramNode:
    stmts = ast.stmts
  elif ast.kind == BlockNode:
    stmts = ast.stmts
  else:
    stmts = @[ast]

  if stmts.len == 0:
    vm.isFinished = true
    vm.currentLine = 0
    return

  vm.pushFrame(BlockFrame, stmts, vm.globalScope)
  vm.currentLine = stmts[0].line

proc step*(vm: VM) =
  ## Execute one statement and advance to the next.
  ##
  ## A statement that calls a user proc pauses with the proc's frame on top;
  ## the following steps run the proc's statements, and the step in which it
  ## returns also finishes the paused statement. Every error a script can
  ## cause is raised as a NimmyError (RuntimeError or LimitError) carrying
  ## the current line; exceptions raised by host natives are wrapped the same
  ## way so a host only ever has to catch NimmyError.
  if vm.isFinished or vm.frames.len == 0:
    vm.isFinished = true
    return

  vm.budget.beginStep()
  vm.suspendRequested = false
  vm.stepSuspended = false

  try:
    vm.charge()
    let frame = vm.currentFrame
    if frame.stmtIndex >= frame.stmts.len:
      vm.advanceFrame()
      return
    vm.currentScope = frame.scope
    vm.execStatement(frame, frame.stmts[frame.stmtIndex])
  except NimmyError as e:
    if e.line == 0:
      e.line = vm.currentLine
      e.msg.add(fmt" at line {vm.currentLine}")
    raise
  except CatchableError as e:
    var wrapped = newException(RuntimeError, e.msg & fmt" at line {vm.currentLine}")
    wrapped.line = vm.currentLine
    wrapped.parent = e
    raise wrapped

proc eval*(vm: VM, node: Node): Value =
  ## Evaluate an AST by stepping until finished.
  vm.load(node)
  while not vm.isFinished:
    vm.step()
  return vm.returnValue

## Debugging primitives

proc callDepth*(vm: VM): int =
  ## Return the current call stack depth (number of function frames).
  vm.functionDepth

proc stepInto*(vm: VM) =
  ## Step into: execute one statement, stepping into function calls.
  ## This is the same as step() - function calls push a frame and the next
  ## step executes inside the function.
  vm.step()

proc stepOver*(vm: VM) =
  ## Step over: execute one statement, running any function calls to completion.
  ## If the current statement calls functions, they all execute.
  if vm.isFinished:
    return

  let startDepth = vm.frames.len
  vm.step()

  # If we entered a new frame (function call), run until we're back
  while not vm.isFinished and vm.frames.len > startDepth:
    vm.step()

proc stepOut*(vm: VM) =
  ## Step out: run until we exit the current function frame.
  ## If we're at the top level, runs to completion.
  if vm.isFinished:
    return

  let startDepth = vm.frames.len

  # Keep stepping until we're at a lower depth (exited a frame)
  while not vm.isFinished:
    vm.step()
    if vm.frames.len < startDepth:
      break

proc addBreakpoint*(vm: VM, line: int) =
  ## Add a breakpoint at the given line.
  vm.breakpoints.incl(line)

proc removeBreakpoint*(vm: VM, line: int) =
  ## Remove a breakpoint from the given line.
  vm.breakpoints.excl(line)

proc clearBreakpoints*(vm: VM) =
  ## Remove all breakpoints.
  vm.breakpoints.clear()

proc hasBreakpoint*(vm: VM, line: int): bool =
  ## Check if there's a breakpoint at the given line.
  line in vm.breakpoints

proc continueExecution*(vm: VM) =
  ## Continue execution until a breakpoint is hit or execution finishes.
  ## After loading, call step() once first to advance past the initial line,
  ## then run until we hit a breakpoint.
  if vm.isFinished:
    return

  # Step at least once
  vm.step()

  # Continue until breakpoint or finished
  while not vm.isFinished:
    if vm.currentLine in vm.breakpoints:
      break
    vm.step()

## Interactive execution

type
  InteractiveResult* = object
    success*: bool
    value*: Value
    output*: seq[string]
    error*: string

proc runInteractive*(vm: VM, code: string): InteractiveResult =
  ## Execute code interactively in the current scope context.
  ## This does NOT affect the main execution state (frames, currentLine,
  ## isFinished, budget): the snippet runs on its own frame stack with a
  ## fresh budget and the main state is restored afterwards.
  ## Returns the result of the expression or last statement.
  ##
  ## If the code is a simple expression, it evaluates and returns the value.
  ## If it's statements, it executes them and returns the last value.
  ## Any output (print) is captured and returned.
  ## Errors are caught and returned without crashing the main execution.

  result = InteractiveResult(success: false, value: nilValue(), output: @[], error: "")

  if code.strip() == "":
    result.success = true
    return

  # Parse the code
  var ast: Node
  try:
    ast = parse(code)
  except NimmyError as e:
    result.error = "Parse error: " & e.msg
    return
  except CatchableError as e:
    result.error = "Parse error: " & e.msg
    return

  if ast.isNil:
    result.success = true
    return

  # Use current scope for evaluation (so we can inspect local variables)
  let evalScope = if vm.currentScope != nil: vm.currentScope else: vm.globalScope

  if ast.kind == IdentNode:
    # Simple identifier - look it up
    result.value = evalScope.lookup(ast.name)
    if result.value.isNil:
      result.error = "Error: Undefined variable '" & ast.name & "'"
    else:
      result.success = true
    return

  # Save the main execution state
  let savedOutputLen = vm.output.len
  let savedFrames = vm.frames
  let savedFinished = vm.isFinished
  let savedLine = vm.currentLine
  let savedScope = vm.currentScope
  let savedReturn = vm.returnValue
  let savedLast = vm.lastValue
  let savedDepth = vm.functionDepth
  let savedBudget = vm.budget
  let savedSuspend = vm.suspendRequested
  let savedStepSuspended = vm.stepSuspended

  vm.budget = newBudget(savedBudget.instructionLimit, savedBudget.allocationLimit,
                        savedBudget.stepInstructionLimit)
  vm.frames = @[]
  vm.isFinished = false
  vm.lastValue = nil
  vm.functionDepth = 0
  vm.suspendRequested = false
  vm.stepSuspended = false

  var stmts: seq[Node] = @[]
  if ast.kind == ProgramNode or ast.kind == BlockNode:
    stmts = ast.stmts
  else:
    stmts = @[ast]

  try:
    if stmts.len > 0:
      vm.pushFrame(BlockFrame, stmts, evalScope)
      vm.currentLine = stmts[0].line
      while not vm.isFinished:
        vm.step()
    if vm.lastValue != nil:
      result.value = vm.lastValue
    result.success = true
  except NimmyError as e:
    result.error = "Error: " & e.msg
  except CatchableError as e:
    result.error = "Error: " & e.msg
  finally:
    vm.frames = savedFrames
    vm.isFinished = savedFinished
    vm.currentLine = savedLine
    vm.currentScope = savedScope
    vm.returnValue = savedReturn
    vm.lastValue = savedLast
    vm.functionDepth = savedDepth
    vm.budget = savedBudget
    vm.suspendRequested = savedSuspend
    vm.stepSuspended = savedStepSuspended

  # Capture any new output
  if vm.output.len > savedOutputLen:
    result.output = vm.output[savedOutputLen..^1]

## Utility functions

proc addProc*(vm: VM, name: string, p: NativeProc, sealed = false) =
  ## Register a native proc. Pass sealed = true to protect a host capability so
  ## scripts can shadow it locally but never replace the global binding, letting
  ## the host trust the name stays the real proc. Convenience builtins are left
  ## unsealed so scripts can still use those names (e.g. `let str = ...`).
  vm.globalScope.define(name, nativeProcValue(name, p), sealed = sealed)

proc getOutput*(vm: VM): string =
  vm.output.join("\n")

proc clearOutput*(vm: VM) =
  vm.output = @[]
