## nimmy_vm.nim
## Virtual Machine for the Nimmy scripting language
##
## Design: Iterative execution with step() as the fundamental operation.
## - step() executes one statement and advances
## - eval() calls step() until finished
## - Function calls push a frame onto the stack and return
## - No recursive evaluation for control flow

import types
import utils
import parser
import std/[strformat, tables, strutils, sets]

const
  ## Default resource limits. A freshly constructed VM is hostile-safe out of
  ## the box — an infinite loop, runaway recursion, or memory bomb aborts with
  ## a catchable error instead of hanging or OOM'ing the host. Hosts can raise
  ## any of these, or set it to 0 to disable that limit entirely.
  ##
  ## The values are deliberately generous: ordinary scripts never reach them,
  ## they only stop runaway ones. Multi-tenant hosts running many untrusted
  ## scripts should tighten them and add OS-level isolation as well.
  DefaultMaxSteps* = 10_000_000        ## ~seconds of interpreter work
  DefaultMaxCallDepth* = 256           ## native recursion depth
  DefaultMaxAllocations* = 256_000_000 ## ~256 MB of script-created data

type
  ControlFlow = enum
    NoneFlow,
    BreakFlow,
    ContinueFlow,
    ReturnFlow

  FrameKind* = enum
    BlockFrame       ## Executing statements in a block
    ForLoopFrame     ## Executing a for loop
    WhileLoopFrame   ## Executing a while loop
    FunctionFrame    ## Inside a function call

  ForIterKind* = enum
    ForArrayIter     ## Iterate an array's backing elements by index
    ForStringIter    ## Iterate a string's characters by index
    ForRangeIter     ## Iterate an integer range lazily (never materialized)

  ExecutionFrame* = ref object
    kind*: FrameKind
    stmts: seq[Node]          ## Statements to execute
    stmtIndex: int            ## Current statement index
    scope: Scope              ## Scope for this frame
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
    # Return value handling
    returnVarName: string     ## Variable to assign return value to (if any)
    returnVarIsConst: bool    ## Whether the return target is const (let vs var)
    returnAssignTarget: Node  ## Assignment target for return value (if any)

  VM* = ref object
    globalScope*: Scope
    currentScope*: Scope
    output*: seq[string]
    debugInfo*: DebugInfo
    controlFlow: ControlFlow
    returnValue: Value
    # Execution state
    frames*: seq[ExecutionFrame]  ## Stack of execution frames
    currentLine*: int            ## Current line number
    isFinished*: bool            ## Whether execution is complete
    # Debugging
    breakpoints*: HashSet[int]   ## Line numbers with breakpoints
    # Resource limits (defense against hostile / runaway scripts).
    # These default to finite safety nets (see DefaultMax* consts); set any to
    # 0 to disable that limit.
    maxSteps*: int               ## Statement budget, 0 means unlimited
    maxCallDepth*: int           ## Cap on native evaluation recursion depth
    evalDepth: int               ## Current native evaluation recursion depth
    maxAllocations*: int         ## Allocation budget in units, 0 means unlimited

proc newVM*(): VM =
  let global = newScope()
  let vm = VM(
    globalScope: global,
    currentScope: global,
    output: @[],
    debugInfo: DebugInfo(),
    controlFlow: NoneFlow,
    returnValue: Value(kind: MissingValue),
    frames: @[],
    currentLine: 0,
    isFinished: true,
    breakpoints: initHashSet[int](),
    maxSteps: DefaultMaxSteps,
    maxCallDepth: DefaultMaxCallDepth,
    evalDepth: 0,
    maxAllocations: DefaultMaxAllocations
  )
  vm.globalScope.define(
    "echo",
    nativeProcValue("echo") do (args: seq[Value]) -> Value:
      var parts: seq[string] = @[]
      for arg in args:
        parts.add($arg)
      let line = parts.join(" ")
      chargeAllocation(line.len + 1)  # bound unbounded output growth
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

proc chargeStep(vm: VM) =
  ## Count one unit of work against the instruction budget. Called per statement
  ## in step() and per loop iteration in the expression-context evaluator, so a
  ## runaway loop aborts on either path. Builtins and value rendering charge the
  ## same budget directly via chargeInstructions.
  chargeInstructions(1)

proc defineChecked(vm: VM, name: string, value: Value, isConst = false) =
  ## Define a script-level binding, refusing to clobber a global the host sealed
  ## (builtins, host APIs). Only blocks redefinition in the scope that holds the
  ## sealed name, so a script can still use the name as a local or parameter.
  if vm.currentScope.isSealedHere(name):
    vm.error("Cannot redefine sealed global '" & name & "'", vm.currentLine, 0)
  vm.currentScope.define(name, value, isConst = isConst)

proc steps*(vm: VM): int =
  ## Instructions charged in the current run (for host introspection).
  instructionsUsed()

# =============================================================================
# Expression Evaluation (non-stepping, used within a single step)
# =============================================================================

# Forward declarations
proc evalExpr(vm: VM, node: Node): Value
proc evalCallExpr(vm: VM, node: Node): (Value, bool, Value, seq[Value])
proc assignToTarget(vm: VM, target: Node, value: Value)

proc evalBinaryOp(vm: VM, node: Node): Value =
  let left = vm.evalExpr(node.binLeft)

  # Short-circuit evaluation for and/or
  if node.binOp == "and":
    if not isTruthy(left):
      return boolValue(false)
    return boolValue(isTruthy(vm.evalExpr(node.binRight)))

  if node.binOp == "or":
    if isTruthy(left):
      return boolValue(true)
    return boolValue(isTruthy(vm.evalExpr(node.binRight)))

  let right = vm.evalExpr(node.binRight)

  case node.binOp
  of "+":
    if left.kind == IntValue and right.kind == IntValue:
      return intValue(left.intVal + right.intVal)
    if left.kind in {IntValue, FloatValue} and right.kind in {IntValue, FloatValue}:
      return floatValue(toFloat(left) + toFloat(right))
    if left.kind == SetValue and right.kind == SetValue:
      var unionSet = left.setVal
      for elem in right.setVal:
        var found = false
        for existing in unionSet:
          if equals(existing, elem):
            found = true
            break
        if not found:
          unionSet.add(elem)
      return setValue(unionSet)
    vm.error("Cannot add " & typeName(left) & " and " & typeName(right), node.line, node.col)

  of "-":
    if left.kind == IntValue and right.kind == IntValue:
      return intValue(left.intVal - right.intVal)
    if left.kind in {IntValue, FloatValue} and right.kind in {IntValue, FloatValue}:
      return floatValue(toFloat(left) - toFloat(right))
    if left.kind == SetValue and right.kind == SetValue:
      var diffSet: seq[Value] = @[]
      for elem in left.setVal:
        var found = false
        for other in right.setVal:
          if equals(elem, other):
            found = true
            break
        if not found:
          diffSet.add(elem)
      return setValue(diffSet)
    vm.error("Cannot subtract " & typeName(right) & " from " & typeName(left), node.line, node.col)

  of "*":
    if left.kind == IntValue and right.kind == IntValue:
      return intValue(left.intVal * right.intVal)
    if left.kind in {IntValue, FloatValue} and right.kind in {IntValue, FloatValue}:
      return floatValue(toFloat(left) * toFloat(right))
    if left.kind == SetValue and right.kind == SetValue:
      var interSet: seq[Value] = @[]
      for elem in left.setVal:
        for other in right.setVal:
          if equals(elem, other):
            interSet.add(elem)
            break
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
      return intValue(left.intVal div right.intVal)
    vm.error("div requires integers", node.line, node.col)

  of "mod", "%":
    if left.kind == IntValue and right.kind == IntValue:
      if right.intVal == 0:
        vm.error("Modulo by zero", node.line, node.col)
      return intValue(left.intVal mod right.intVal)
    vm.error("mod requires integers", node.line, node.col)

  of "&":
    return stringValue($left & $right)

  of "==":
    return boolValue(equals(left, right))

  of "!=":
    return boolValue(not equals(left, right))

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
        if equals(left, elem):
          return boolValue(true)
      return boolValue(false)
    of StringValue:
      if left.kind != StringValue:
        vm.error("'in' requires string on left for string search", node.line, node.col)
      chargeInstructions(right.strVal.len)  # substring scan is O(n)
      return boolValue(left.strVal in right.strVal)
    of TableValue:
      if left.kind != StringValue:
        vm.error("'in' requires string key for table", node.line, node.col)
      return boolValue(right.tableVal.hasKey(left.strVal))
    of SetValue:
      return boolValue(setContains(right, left))
    else:
      vm.error("'in' not supported for " & typeName(right), node.line, node.col)

  else:
    vm.error("Unknown operator: " & node.binOp, node.line, node.col)

proc evalUnaryOp(vm: VM, node: Node): Value =
  let operand = vm.evalExpr(node.unOperand)

  case node.unOp
  of "-":
    if operand.kind == IntValue:
      return intValue(-operand.intVal)
    if operand.kind == FloatValue:
      return floatValue(-operand.floatVal)
    vm.error("Cannot negate " & typeName(operand), node.line, node.col)
  of "not":
    return boolValue(not isTruthy(operand))
  of "$":
    return stringValue($operand)
  else:
    vm.error("Unknown unary operator: " & node.unOp, node.line, node.col)

proc evalIndex(vm: VM, node: Node): Value =
  let obj = vm.evalExpr(node.indexee)
  let index = vm.evalExpr(node.index)

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
    return stringValue($obj.strVal[i])

  if obj.kind == TableValue:
    if index.kind != StringValue:
      vm.error("Table key must be a string", node.line, node.col)
    if obj.tableVal.hasKey(index.strVal):
      return obj.tableVal[index.strVal]
    return nilValue()

  vm.error(fmt"Cannot index {typeName(obj)}", node.line, node.col)

proc evalDot(vm: VM, node: Node): Value =
  let obj = vm.evalExpr(node.dotLeft)

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

  # Try UFCS: look up as a function and call with obj as first argument
  let funcVal = vm.currentScope.lookup(node.dotField)
  if not funcVal.isMissing:
    if funcVal.kind == NativeProcValue:
      # Call native proc with obj as argument (UFCS without parens)
      chargeInstructions(1)
      return (funcVal.nativeProc)(@[obj])
    elif funcVal.kind == ProcValue:
      # Call user-defined proc with obj as argument (UFCS without parens)
      if funcVal.procParams.len != 1:
        vm.error("UFCS call requires function with 1 parameter", node.line, node.col)
      if vm.evalDepth >= vm.maxCallDepth:
        vm.error("Maximum call depth exceeded", node.line, node.col)
      let savedScope = vm.currentScope
      inc vm.evalDepth
      vm.currentScope = newScope(funcVal.procClosure)
      vm.currentScope.define(funcVal.procParams[0], obj)
      var funcResult: Value
      try:
        funcResult = vm.evalExpr(funcVal.procBody)
      finally:
        dec vm.evalDepth
        vm.currentScope = savedScope
      if vm.controlFlow == ReturnFlow:
        funcResult = vm.returnValue
        vm.controlFlow = NoneFlow
        vm.returnValue = Value(kind: MissingValue)
      return funcResult

  if obj.kind == ObjectValue:
    vm.error("Object has no field '" & node.dotField & "'", node.line, node.col)
  else:
    vm.error("Cannot access field of " & typeName(obj), node.line, node.col)

proc evalCallExpr(vm: VM, node: Node): (Value, bool, Value, seq[Value]) =
  ## Evaluate a call expression.
  ## Returns (result, needsFrame, callee, args)
  ## If needsFrame is true, the caller should push a frame for the function.
  var callee: Value
  var args: seq[Value] = @[]
  var ufcsReceiver = Value(kind: MissingValue)

  # Handle UFCS: obj.method(args) or obj.method
  if node.callee.kind == DotNode:
    let obj = vm.evalExpr(node.callee.dotLeft)
    let methodName = node.callee.dotField

    if obj.kind == ObjectValue and obj.objFields.hasKey(methodName):
      callee = obj.objFields[methodName]
    else:
      callee = vm.currentScope.lookup(methodName)
      if callee.isMissing:
        vm.error("Unknown function: " & methodName, node.line, node.col)
      ufcsReceiver = obj
  elif node.callee.kind == IdentNode:
    callee = vm.currentScope.lookup(node.callee.name)
    if callee.isMissing:
      vm.error("Unknown function: " & node.callee.name, node.line, node.col)
  else:
    callee = vm.evalExpr(node.callee)

  if not ufcsReceiver.isMissing:
    args.add(ufcsReceiver)
  for arg in node.args:
    args.add(vm.evalExpr(arg))

  if callee.kind == NativeProcValue:
    chargeInstructions(1)
    return ((callee.nativeProc)(args), false, Value(kind: MissingValue), @[])

  if callee.kind == TypeValue:
    let obj = objectValue(callee.typeNameVal)
    for i, arg in node.args:
      if i < callee.typeFields.len:
        obj.objFields[callee.typeFields[i]] = args[i]
    return (obj, false, Value(kind: MissingValue), @[])

  if callee.kind != ProcValue:
    vm.error("Cannot call " & typeName(callee), node.line, node.col)

  if args.len != callee.procParams.len:
    if callee.procParams.len == 1 and args.len > 1:
      args = @[argsValue(args)]
    else:
      vm.error("Expected " & $callee.procParams.len & " arguments, got " & $args.len, node.line, node.col)

  # User-defined function - needs a frame
  return (nilValue(), true, callee, args)

proc evalExpr(vm: VM, node: Node): Value =
  ## Evaluate an expression (within a single step).
  ## Does NOT handle statements that create new frames.
  if node.isNil:
    return nilValue()

  case node.kind
  of IntLitNode:
    return intValue(node.intVal)
  of FloatLitNode:
    return floatValue(node.floatVal)
  of StrLitNode:
    return stringValue(node.strVal)
  of BoolLitNode:
    return boolValue(node.boolVal)
  of NilLitNode:
    return nilValue()
  of IdentNode:
    result = vm.currentScope.lookup(node.name)
    if result.isMissing:
      vm.error(fmt"Undefined variable '{node.name}'", node.line, node.col)
  of BinaryOpNode:
    return vm.evalBinaryOp(node)
  of UnaryOpNode:
    return vm.evalUnaryOp(node)
  of CallNode:
    let (callResult, needsFrame, callee, args) = vm.evalCallExpr(node)
    if needsFrame:
      # This shouldn't happen during expression evaluation within step
      # But we handle it by executing the function synchronously.
      # Depth-cap the native recursion so a hostile script cannot overflow
      # the host's C stack (an uncatchable crash).
      if vm.evalDepth >= vm.maxCallDepth:
        vm.error("Maximum call depth exceeded", node.line, node.col)
      let savedScope = vm.currentScope
      inc vm.evalDepth
      vm.currentScope = newScope(callee.procClosure)
      for i, param in callee.procParams:
        vm.currentScope.define(param, args[i])
      # Recursively evaluate (fallback for expressions with calls)
      var funcResult: Value
      try:
        funcResult = vm.evalExpr(callee.procBody)
      finally:
        dec vm.evalDepth
        vm.currentScope = savedScope
      if vm.controlFlow == ReturnFlow:
        funcResult = vm.returnValue
        vm.controlFlow = NoneFlow
        vm.returnValue = Value(kind: MissingValue)
      return funcResult
    return callResult
  of IndexNode:
    return vm.evalIndex(node)
  of DotNode:
    return vm.evalDot(node)
  of ArrayNode:
    var elems: seq[Value] = @[]
    for elem in node.arrayElems:
      elems.add(vm.evalExpr(elem))
    return arrayValue(elems)
  of TableNode:
    result = tableValue()
    for i in 0..<node.tableKeys.len:
      let key = vm.evalExpr(node.tableKeys[i])
      let val = vm.evalExpr(node.tableVals[i])
      if key.kind != StringValue:
        vm.error("Table key must be a string", node.line, node.col)
      result.tableVal[key.strVal] = val
  of SetNode:
    var elems: seq[Value] = @[]
    for elem in node.setElems:
      let val = vm.evalExpr(elem)
      var found = false
      for existing in elems:
        if equals(existing, val):
          found = true
          break
      if not found:
        elems.add(val)
    return setValue(elems)
  of RangeNode:
    let startVal = vm.evalExpr(node.rangeStart)
    let endVal = vm.evalExpr(node.rangeEnd)
    if startVal.kind != IntValue or endVal.kind != IntValue:
      vm.error("Range bounds must be integers", node.line, node.col)
    return rangeValue(startVal.intVal, endVal.intVal, node.rangeInclusive)
  of BlockNode:
    # Evaluate block as expression (returns last value)
    result = nilValue()
    for stmt in node.stmts:
      result = vm.evalExpr(stmt)
      if vm.controlFlow != NoneFlow:
        break
  of ReturnStmtNode:
    if node.returnValue != nil:
      vm.returnValue = vm.evalExpr(node.returnValue)
    else:
      vm.returnValue = nilValue()
    vm.controlFlow = ReturnFlow
    return vm.returnValue

  of IfStmtNode:
    let cond = vm.evalExpr(node.ifCond)
    if isTruthy(cond):
      return vm.evalExpr(node.ifBody)

    for branch in node.elifBranches:
      let elifCond = vm.evalExpr(branch.elifCond)
      if isTruthy(elifCond):
        return vm.evalExpr(branch.elifBody)

    if node.elseBranch != nil:
      let elseNode = node.elseBranch
      if elseNode.kind == ElseBranchNode:
        return vm.evalExpr(elseNode.elseBody)
      else:
        return vm.evalExpr(elseNode)

    return nilValue()

  of LetStmtNode:
    let value = vm.evalExpr(node.varValue)
    vm.defineChecked(node.varName, value, isConst = true)
    return nilValue()

  of VarStmtNode:
    let value = vm.evalExpr(node.varValue)
    vm.defineChecked(node.varName, value, isConst = false)
    return nilValue()

  of AssignNode:
    let value = vm.evalExpr(node.assignValue)
    vm.assignToTarget(node.assignTarget, value)
    return nilValue()

  of ForStmtNode:
    let iter = vm.evalExpr(node.forIter)
    let savedScope = vm.currentScope

    # Iterate lazily: produce one loop value at a time instead of materializing
    # the whole sequence, so a huge range does not allocate up front. Each
    # iteration charges the step budget so the loop stays bounded here too.
    template runBody(makeVal: Value): bool =
      ## Returns true if the loop should stop.
      vm.chargeStep()
      vm.currentScope = newScope(savedScope)
      vm.currentScope.define(node.forVar, makeVal)
      discard vm.evalExpr(node.forBody)
      var stop = false
      if vm.controlFlow == BreakFlow:
        vm.controlFlow = NoneFlow
        stop = true
      elif vm.controlFlow == ContinueFlow:
        vm.controlFlow = NoneFlow
      elif vm.controlFlow == ReturnFlow:
        stop = true
      stop

    case iter.kind
    of RangeValue:
      let s = iter.rangeStart
      let e = if iter.rangeInclusive: iter.rangeEnd else: iter.rangeEnd - 1
      var i = s
      while i <= e:
        if runBody(intValue(i)):
          break
        if i == e:  # avoid int64 overflow at the top of the range
          break
        i += 1
    of ArrayValue:
      for val in iter.arrayVal:
        if runBody(val):
          break
    of StringValue:
      for c in iter.strVal:
        if runBody(stringValue($c)):
          break
    else:
      discard

    vm.currentScope = savedScope
    return nilValue()

  of WhileStmtNode:
    let savedScope = vm.currentScope
    vm.currentScope = newScope(savedScope)
    while true:
      vm.chargeStep()
      let cond = vm.evalExpr(node.whileCond)
      if not isTruthy(cond):
        break
      discard vm.evalExpr(node.whileBody)
      if vm.controlFlow == BreakFlow:
        vm.controlFlow = NoneFlow
        break
      if vm.controlFlow == ContinueFlow:
        vm.controlFlow = NoneFlow
      if vm.controlFlow == ReturnFlow:
        break
    vm.currentScope = savedScope
    return nilValue()

  of BreakStmtNode:
    vm.controlFlow = BreakFlow
    return nilValue()

  of ContinueStmtNode:
    vm.controlFlow = ContinueFlow
    return nilValue()

  of ProcDefNode:
    let procVal = procValue(node.procName, node.procParams, node.procBody, vm.currentScope)
    vm.defineChecked(node.procName, procVal)
    return nilValue()

  of TypeDefNode:
    var fields: seq[string] = @[]
    if node.typeBody.kind == ObjectDefNode:
      for field in node.typeBody.objectFields:
        fields.add(field.fieldName)
    let typeVal = typeValue(node.typeName, fields)
    vm.defineChecked(node.typeName, typeVal)
    return nilValue()

  else:
    return nilValue()

# =============================================================================
# Statement Execution (used by step)
# =============================================================================

proc assignToTarget(vm: VM, target: Node, value: Value) =
  ## Assign an already-evaluated value to an assignment target with full
  ## bounds and type checking. Every write path routes through here so none
  ## can bypass the checks (prevents out-of-bounds and type-confused writes,
  ## which are memory-unsafe under -d:danger and abort the host otherwise).
  case target.kind
  of IdentNode:
    let name = target.name
    if vm.currentScope.isSealed(name):
      vm.error(fmt"Cannot assign to sealed global '{name}'", target.line, target.col)
    if vm.currentScope.isConstant(name):
      vm.error(fmt"Cannot assign to constant '{name}'", target.line, target.col)
    if not vm.currentScope.assign(name, value):
      vm.error(fmt"Undefined variable '{name}'", target.line, target.col)

  of IndexNode:
    let obj = vm.evalExpr(target.indexee)
    let index = vm.evalExpr(target.index)

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
      obj.tableVal[index.strVal] = value
    else:
      vm.error(fmt"Cannot index assign {typeName(obj)}", target.line, target.col)

  of DotNode:
    let obj = vm.evalExpr(target.dotLeft)
    if obj.kind == ObjectValue:
      obj.objFields[target.dotField] = value
    else:
      vm.error(fmt"Cannot assign field of {typeName(obj)}", target.line, target.col)

  else:
    vm.error("Invalid assignment target", target.line, target.col)

proc execAssign(vm: VM, node: Node) =
  let value = vm.evalExpr(node.assignValue)
  vm.assignToTarget(node.assignTarget, value)

proc execProcDef(vm: VM, node: Node) =
  let procVal = procValue(node.procName, node.procParams, node.procBody, vm.currentScope)
  vm.defineChecked(node.procName, procVal)

proc execTypeDef(vm: VM, node: Node) =
  var fields: seq[string] = @[]
  if node.typeBody.kind == ObjectDefNode:
    for field in node.typeBody.objectFields:
      fields.add(field.fieldName)
  let typeVal = typeValue(node.typeName, fields)
  vm.defineChecked(node.typeName, typeVal)

# =============================================================================
# Stepping API
# =============================================================================

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
      vm.currentScope = frame.returnToScope

proc currentFrame(vm: VM): ExecutionFrame =
  if vm.frames.len > 0:
    return vm.frames[^1]
  return nil

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

proc advanceFrame(vm: VM)

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

proc advanceFrame(vm: VM) =
  ## Called when a frame is complete, pops it and advances parent.
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
      let parentScope = frame.scope.parent
      let iterScope = newScope(parentScope)
      iterScope.define(frame.forNode.forVar, frame.forCurrentValue())
      frame.scope = iterScope
      vm.currentScope = iterScope
      vm.updateLine()

  of WhileLoopFrame:
    let cond = vm.evalExpr(frame.whileNode.whileCond)
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
    # Handle return value assignment if needed
    let returnVal = if not vm.returnValue.isMissing: vm.returnValue else: nilValue()
    let varName = frame.returnVarName
    let varIsConst = frame.returnVarIsConst
    let assignTarget = frame.returnAssignTarget

    vm.popFrame()

    # Assign return value if we have a target
    if varName != "":
      vm.defineChecked(varName, returnVal, isConst = varIsConst)
    elif assignTarget != nil:
      # Handle assignment target (for cases like x = foo())
      if assignTarget.kind == IdentNode:
        discard vm.currentScope.assign(assignTarget.name, returnVal)

    vm.returnValue = Value(kind: MissingValue)

    if vm.frames.len == 0:
      vm.isFinished = true
    else:
      vm.updateLine()

  of BlockFrame:
    vm.popFrame()
    if vm.frames.len == 0:
      vm.isFinished = true
    else:
      vm.updateLine()

proc load*(vm: VM, ast: Node) =
  ## Load an AST for step-by-step execution.
  vm.frames = @[]
  vm.isFinished = false
  vm.controlFlow = NoneFlow
  vm.returnValue = Value(kind: MissingValue)
  vm.currentScope = vm.globalScope
  resetInstructions(vm.maxSteps)
  resetAllocations(vm.maxAllocations)

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
  if vm.isFinished or vm.frames.len == 0:
    vm.isFinished = true
    return

  vm.chargeStep()

  let frame = vm.currentFrame

  # Handle completed frames (shouldn't happen, but be safe)
  if frame.stmtIndex >= frame.stmts.len:
    vm.advanceFrame()
    return

  let stmt = frame.stmts[frame.stmtIndex]
  vm.currentScope = frame.scope

  case stmt.kind
  of LetStmtNode, VarStmtNode:
    let isConst = stmt.kind == LetStmtNode
    let varName = stmt.varName
    let valueNode = stmt.varValue

    # Check if the value is a function call
    if valueNode != nil and valueNode.kind == CallNode:
      let (callResult, needsFrame, callee, args) = vm.evalCallExpr(valueNode)
      if needsFrame:
        # Push function frame, store where to assign result
        let savedScope = vm.currentScope
        let funcScope = newScope(callee.procClosure)
        vm.currentScope = funcScope

        for i, param in callee.procParams:
          funcScope.define(param, args[i])

        var bodyStmts: seq[Node] = @[]
        if callee.procBody.kind == BlockNode:
          bodyStmts = callee.procBody.stmts
        else:
          bodyStmts = @[callee.procBody]

        let funcFrame = ExecutionFrame(
          kind: FunctionFrame,
          stmts: bodyStmts,
          stmtIndex: 0,
          scope: funcScope,
          funcName: callee.procName,
          returnToScope: savedScope,
          returnVarName: varName,
          returnVarIsConst: isConst
        )
        vm.frames.add(funcFrame)
        frame.stmtIndex += 1
        vm.updateLine()
        return
      else:
        # Native function call - use result directly
        vm.defineChecked(varName, callResult, isConst = isConst)
    else:
      # Normal expression
      let value = vm.evalExpr(valueNode)
      vm.defineChecked(varName, value, isConst = isConst)

    frame.stmtIndex += 1
    vm.updateLine()

  of AssignNode:
    let valueNode = stmt.assignValue

    # Check if the value is a function call
    if valueNode != nil and valueNode.kind == CallNode:
      let (callResult, needsFrame, callee, args) = vm.evalCallExpr(valueNode)
      if needsFrame:
        # Push function frame, store where to assign result
        let savedScope = vm.currentScope
        let funcScope = newScope(callee.procClosure)
        vm.currentScope = funcScope

        for i, param in callee.procParams:
          funcScope.define(param, args[i])

        var bodyStmts: seq[Node] = @[]
        if callee.procBody.kind == BlockNode:
          bodyStmts = callee.procBody.stmts
        else:
          bodyStmts = @[callee.procBody]

        let funcFrame = ExecutionFrame(
          kind: FunctionFrame,
          stmts: bodyStmts,
          stmtIndex: 0,
          scope: funcScope,
          funcName: callee.procName,
          returnToScope: savedScope,
          returnAssignTarget: stmt.assignTarget
        )
        vm.frames.add(funcFrame)
        frame.stmtIndex += 1
        vm.updateLine()
        return
      else:
        # Native function - use callResult directly
        vm.assignToTarget(stmt.assignTarget, callResult)
    else:
      vm.execAssign(stmt)

    frame.stmtIndex += 1
    vm.updateLine()

  of ProcDefNode:
    vm.execProcDef(stmt)
    frame.stmtIndex += 1
    vm.updateLine()

  of TypeDefNode:
    vm.execTypeDef(stmt)
    frame.stmtIndex += 1
    vm.updateLine()

  of IfStmtNode:
    let cond = vm.evalExpr(stmt.ifCond)
    frame.stmtIndex += 1

    var bodyStmts: seq[Node] = @[]
    var foundBranch = false

    if isTruthy(cond):
      if stmt.ifBody.kind == BlockNode:
        bodyStmts = stmt.ifBody.stmts
      else:
        bodyStmts = @[stmt.ifBody]
      foundBranch = true
    else:
      for branch in stmt.elifBranches:
        let elifCond = vm.evalExpr(branch.elifCond)
        if isTruthy(elifCond):
          if branch.elifBody.kind == BlockNode:
            bodyStmts = branch.elifBody.stmts
          else:
            bodyStmts = @[branch.elifBody]
          foundBranch = true
          break

      if not foundBranch and stmt.elseBranch != nil:
        let elseNode = stmt.elseBranch
        var elseBodyNode: Node
        if elseNode.kind == ElseBranchNode:
          elseBodyNode = elseNode.elseBody
        else:
          elseBodyNode = elseNode  # Direct body node

        if elseBodyNode.kind == BlockNode:
          bodyStmts = elseBodyNode.stmts
        else:
          bodyStmts = @[elseBodyNode]
        foundBranch = true

    if foundBranch and bodyStmts.len > 0:
      let newScope = newScope(vm.currentScope)
      vm.currentScope = newScope
      vm.pushFrame(BlockFrame, bodyStmts, newScope)

    vm.updateLine()

  of ForStmtNode:
    let iter = vm.evalExpr(stmt.forIter)
    frame.stmtIndex += 1

    var bodyStmts: seq[Node] = @[]
    if stmt.forBody.kind == BlockNode:
      bodyStmts = stmt.forBody.stmts
    else:
      bodyStmts = @[stmt.forBody]

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

    if loopFrame != nil:
      let newScope = newScope(vm.currentScope)
      vm.currentScope = newScope
      loopFrame.scope = newScope
      newScope.define(stmt.forVar, loopFrame.forCurrentValue())
      vm.frames.add(loopFrame)

    vm.updateLine()

  of WhileStmtNode:
    let cond = vm.evalExpr(stmt.whileCond)
    frame.stmtIndex += 1  # Advance past while statement before entering loop

    if isTruthy(cond):
      var bodyStmts: seq[Node] = @[]
      if stmt.whileBody.kind == BlockNode:
        bodyStmts = stmt.whileBody.stmts
      else:
        bodyStmts = @[stmt.whileBody]

      let newScope = newScope(vm.currentScope)
      vm.currentScope = newScope

      let loopFrame = ExecutionFrame(
        kind: WhileLoopFrame,
        stmts: bodyStmts,
        stmtIndex: 0,
        scope: newScope,
        whileNode: stmt
      )
      vm.frames.add(loopFrame)
      vm.updateLine()
    else:
      vm.updateLine()

  of ReturnStmtNode:
    if stmt.returnValue != nil:
      vm.returnValue = vm.evalExpr(stmt.returnValue)
    else:
      vm.returnValue = nilValue()

    # Pop frames until we exit the function, handling return value
    while vm.frames.len > 0:
      let f = vm.currentFrame
      if f.kind == FunctionFrame:
        # Handle return value assignment
        let returnVal = if not vm.returnValue.isMissing: vm.returnValue else: nilValue()
        let varName = f.returnVarName
        let varIsConst = f.returnVarIsConst
        let assignTarget = f.returnAssignTarget

        vm.popFrame()

        # Assign return value if we have a target
        if varName != "":
          vm.defineChecked(varName, returnVal, isConst = varIsConst)
        elif assignTarget != nil:
          if assignTarget.kind == IdentNode:
            discard vm.currentScope.assign(assignTarget.name, returnVal)

        vm.returnValue = Value(kind: MissingValue)
        break
      else:
        vm.popFrame()

    if vm.frames.len == 0:
      vm.isFinished = true
    else:
      vm.updateLine()

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

  of CallNode:
    let (_, needsFrame, callee, args) = vm.evalCallExpr(stmt)

    if needsFrame:
      # Push function frame
      let savedScope = vm.currentScope
      let funcScope = newScope(callee.procClosure)
      vm.currentScope = funcScope

      for i, param in callee.procParams:
        funcScope.define(param, args[i])

      var bodyStmts: seq[Node] = @[]
      if callee.procBody.kind == BlockNode:
        bodyStmts = callee.procBody.stmts
      else:
        bodyStmts = @[callee.procBody]

      let funcFrame = ExecutionFrame(
        kind: FunctionFrame,
        stmts: bodyStmts,
        stmtIndex: 0,
        scope: funcScope,
        funcName: callee.procName,
        returnToScope: savedScope
      )
      vm.frames.add(funcFrame)
      frame.stmtIndex += 1  # Advance parent frame
      vm.updateLine()
    else:
      frame.stmtIndex += 1
      vm.updateLine()

  else:
    # Generic expression statement
    discard vm.evalExpr(stmt)
    frame.stmtIndex += 1
    vm.updateLine()

proc eval*(vm: VM, node: Node): Value =
  ## Evaluate an AST by stepping until finished.
  vm.load(node)
  while not vm.isFinished:
    vm.step()
  return vm.returnValue

# =============================================================================
# Debugging Primitives
# =============================================================================

proc callDepth*(vm: VM): int =
  ## Return the current call stack depth (number of function frames).
  result = 0
  for frame in vm.frames:
    if frame.kind == FunctionFrame:
      result += 1

proc stepInto*(vm: VM) =
  ## Step into: execute one statement, stepping into function calls.
  ## This is the same as step() - function calls push a frame and the next
  ## step executes inside the function.
  vm.step()

proc stepOver*(vm: VM) =
  ## Step over: execute one statement, running any function calls to completion.
  ## If the current statement is a function call, the entire function executes.
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

# =============================================================================
# Interactive Execution
# =============================================================================

type
  InteractiveResult* = object
    success*: bool
    value*: Value
    output*: seq[string]
    error*: string

proc runInteractive*(vm: VM, code: string): InteractiveResult =
  ## Execute code interactively in the current scope context.
  ## This does NOT affect the main execution state (frames, currentLine, isFinished).
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

  # Save current VM state
  let savedOutputLen = vm.output.len

  # Use current scope for evaluation (so we can inspect local variables)
  let evalScope = if vm.currentScope != nil: vm.currentScope else: vm.globalScope
  resetInstructions(vm.maxSteps)
  resetAllocations(vm.maxAllocations)

  # Try to evaluate
  try:
    case ast.kind
    of BlockNode, ProgramNode:
      # Multiple statements - execute each
      for stmt in ast.stmts:
        case stmt.kind
        of LetStmtNode, VarStmtNode:
          # Variable declaration in interactive mode
          let varName = stmt.varName
          let varValue = if stmt.varValue.isNil: nilValue() else: vm.evalExpr(stmt.varValue)
          vm.defineChecked(varName, varValue)
        of AssignNode:
          # Assignment (dispatch on target kind; never assume a bare name)
          let val = vm.evalExpr(stmt.assignValue)
          vm.assignToTarget(stmt.assignTarget, val)
          result.value = val
        of CallNode:
          # Function call as statement
          let val = vm.evalExpr(stmt)
          result.value = val
        else:
          # Try as expression
          result.value = vm.evalExpr(stmt)

    of IdentNode:
      # Simple identifier - look it up
      result.value = evalScope.lookup(ast.name)

    of CallNode, BinaryOpNode, UnaryOpNode, IntLitNode, FloatLitNode, StrLitNode, BoolLitNode, NilLitNode, ArrayNode, IndexNode, DotNode:
      # Expression - evaluate it
      result.value = vm.evalExpr(ast)

    else:
      # Try as expression anyway
      result.value = vm.evalExpr(ast)

    result.success = true

  except NimmyError as e:
    result.error = "Error: " & e.msg
  except CatchableError as e:
    result.error = "Error: " & e.msg

  # Capture any new output
  if vm.output.len > savedOutputLen:
    result.output = vm.output[savedOutputLen..^1]

# =============================================================================
# Utility Functions
# =============================================================================

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
