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
import std/[strformat, tables, strutils, sets]

type
  ControlFlow = enum
    cfNone,
    cfBreak,
    cfContinue,
    cfReturn

  FrameKind = enum
    fkBlock       ## Executing statements in a block
    fkForLoop     ## Executing a for loop
    fkWhileLoop   ## Executing a while loop
    fkFunction    ## Inside a function call

  ExecutionFrame* = ref object
    kind: FrameKind
    stmts: seq[Node]          ## Statements to execute
    stmtIndex: int            ## Current statement index
    scope: Scope              ## Scope for this frame
    # For loops
    forNode: Node             ## The for loop node
    forValues: seq[Value]     ## Values to iterate over
    forIndex: int             ## Current iteration index
    # While loops
    whileNode: Node           ## The while loop node
    # Functions
    funcName: string          ## Function name (for debugging)
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
    frames: seq[ExecutionFrame]  ## Stack of execution frames
    currentLine*: int            ## Current line number
    isFinished*: bool            ## Whether execution is complete
    # Debugging
    breakpoints*: HashSet[int]   ## Line numbers with breakpoints

proc newVM*(): VM =
  let global = newScope()
  VM(
    globalScope: global,
    currentScope: global,
    output: @[],
    debugInfo: DebugInfo(),
    controlFlow: cfNone,
    returnValue: nil,
    frames: @[],
    currentLine: 0,
    isFinished: true,
    breakpoints: initHashSet[int]()
  )

proc error(vm: VM, msg: string, line, col: int) =
  var e = newException(RuntimeError, fmt"{msg} at line {line}, column {col}")
  e.line = line
  e.col = col
  raise e

# =============================================================================
# Expression Evaluation (non-stepping, used within a single step)
# =============================================================================

# Forward declarations
proc evalExpr(vm: VM, node: Node): Value
proc evalCallExpr(vm: VM, node: Node): (Value, bool, Value, seq[Value])

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
    if left.kind == vkInt and right.kind == vkInt:
      return intValue(left.intVal + right.intVal)
    if left.kind in {vkInt, vkFloat} and right.kind in {vkInt, vkFloat}:
      return floatValue(toFloat(left) + toFloat(right))
    if left.kind == vkSet and right.kind == vkSet:
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
    if left.kind == vkInt and right.kind == vkInt:
      return intValue(left.intVal - right.intVal)
    if left.kind in {vkInt, vkFloat} and right.kind in {vkInt, vkFloat}:
      return floatValue(toFloat(left) - toFloat(right))
    if left.kind == vkSet and right.kind == vkSet:
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
    if left.kind == vkInt and right.kind == vkInt:
      return intValue(left.intVal * right.intVal)
    if left.kind in {vkInt, vkFloat} and right.kind in {vkInt, vkFloat}:
      return floatValue(toFloat(left) * toFloat(right))
    if left.kind == vkSet and right.kind == vkSet:
      var interSet: seq[Value] = @[]
      for elem in left.setVal:
        for other in right.setVal:
          if equals(elem, other):
            interSet.add(elem)
            break
      return setValue(interSet)
    vm.error("Cannot multiply " & typeName(left) & " and " & typeName(right), node.line, node.col)
  
  of "/":
    if left.kind in {vkInt, vkFloat} and right.kind in {vkInt, vkFloat}:
      let r = toFloat(right)
      if r == 0:
        vm.error("Division by zero", node.line, node.col)
      return floatValue(toFloat(left) / r)
    vm.error("Cannot divide " & typeName(left) & " by " & typeName(right), node.line, node.col)
  
  of "div":
    if left.kind == vkInt and right.kind == vkInt:
      if right.intVal == 0:
        vm.error("Division by zero", node.line, node.col)
      return intValue(left.intVal div right.intVal)
    vm.error("div requires integers", node.line, node.col)
  
  of "mod", "%":
    if left.kind == vkInt and right.kind == vkInt:
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
    of vkArray:
      for elem in right.arrayVal:
        if equals(left, elem):
          return boolValue(true)
      return boolValue(false)
    of vkString:
      if left.kind != vkString:
        vm.error("'in' requires string on left for string search", node.line, node.col)
      return boolValue(left.strVal in right.strVal)
    of vkTable:
      if left.kind != vkString:
        vm.error("'in' requires string key for table", node.line, node.col)
      return boolValue(right.tableVal.hasKey(left.strVal))
    of vkSet:
      return boolValue(setContains(right, left))
    else:
      vm.error("'in' not supported for " & typeName(right), node.line, node.col)
  
  else:
    vm.error("Unknown operator: " & node.binOp, node.line, node.col)

proc evalUnaryOp(vm: VM, node: Node): Value =
  let operand = vm.evalExpr(node.unOperand)
  
  case node.unOp
  of "-":
    if operand.kind == vkInt:
      return intValue(-operand.intVal)
    if operand.kind == vkFloat:
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
  
  if obj.kind == vkArray:
    if index.kind != vkInt:
      vm.error("Array index must be an integer", node.line, node.col)
    let i = index.intVal
    if i < 0 or i >= obj.arrayVal.len:
      vm.error(fmt"Array index {i} out of bounds", node.line, node.col)
    return obj.arrayVal[i]
  
  if obj.kind == vkString:
    if index.kind != vkInt:
      vm.error("String index must be an integer", node.line, node.col)
    let i = index.intVal
    if i < 0 or i >= obj.strVal.len:
      vm.error(fmt"String index {i} out of bounds", node.line, node.col)
    return stringValue($obj.strVal[i])
  
  if obj.kind == vkTable:
    if index.kind != vkString:
      vm.error("Table key must be a string", node.line, node.col)
    if obj.tableVal.hasKey(index.strVal):
      return obj.tableVal[index.strVal]
    return nilValue()
  
  vm.error(fmt"Cannot index {typeName(obj)}", node.line, node.col)

proc evalDot(vm: VM, node: Node): Value =
  let obj = vm.evalExpr(node.dotLeft)
  
  if obj.kind == vkObject:
    if obj.objFields.hasKey(node.dotField):
      return obj.objFields[node.dotField]
    # Don't error yet - try UFCS below
  
  if obj.kind == vkArray:
    if node.dotField == "len":
      return intValue(obj.arrayVal.len)
  
  if obj.kind == vkString:
    if node.dotField == "len":
      return intValue(obj.strVal.len)
  
  if obj.kind == vkSet:
    if node.dotField == "len" or node.dotField == "card":
      return intValue(obj.setVal.len)
  
  if obj.kind == vkTable:
    if node.dotField == "len":
      return intValue(obj.tableVal.len)
  
  # Try UFCS: look up as a function and call with obj as first argument
  let funcVal = vm.currentScope.lookup(node.dotField)
  if funcVal != nil:
    if funcVal.kind == vkNativeProc:
      # Call native proc with obj as argument (UFCS without parens)
      return funcVal.nativeProc(@[obj])
    elif funcVal.kind == vkProc:
      # Call user-defined proc with obj as argument (UFCS without parens)
      if funcVal.procParams.len != 1:
        vm.error("UFCS call requires function with 1 parameter", node.line, node.col)
      let savedScope = vm.currentScope
      vm.currentScope = newScope(funcVal.procClosure)
      vm.currentScope.define(funcVal.procParams[0], obj)
      var funcResult = vm.evalExpr(funcVal.procBody)
      if vm.controlFlow == cfReturn:
        funcResult = vm.returnValue
        vm.controlFlow = cfNone
        vm.returnValue = nil
      vm.currentScope = savedScope
      return funcResult
  
  if obj.kind == vkObject:
    vm.error("Object has no field '" & node.dotField & "'", node.line, node.col)
  else:
    vm.error("Cannot access field of " & typeName(obj), node.line, node.col)

proc evalCallExpr(vm: VM, node: Node): (Value, bool, Value, seq[Value]) =
  ## Evaluate a call expression. 
  ## Returns (result, needsFrame, callee, args)
  ## If needsFrame is true, the caller should push a frame for the function.
  var callee: Value
  var args: seq[Value] = @[]
  var ufcsReceiver: Value = nil
  
  # Handle UFCS: obj.method(args) or obj.method
  if node.callee.kind == nkDot:
    let obj = vm.evalExpr(node.callee.dotLeft)
    let methodName = node.callee.dotField
    
    if obj.kind == vkObject and obj.objFields.hasKey(methodName):
      callee = obj.objFields[methodName]
    else:
      callee = vm.currentScope.lookup(methodName)
      if callee.isNil:
        vm.error("Unknown function: " & methodName, node.line, node.col)
      ufcsReceiver = obj
  elif node.callee.kind == nkIdent:
    callee = vm.currentScope.lookup(node.callee.name)
    if callee.isNil:
      vm.error("Unknown function: " & node.callee.name, node.line, node.col)
  else:
    callee = vm.evalExpr(node.callee)
  
  if ufcsReceiver != nil:
    args.add(ufcsReceiver)
  for arg in node.args:
    args.add(vm.evalExpr(arg))
  
  if callee.kind == vkNativeProc:
    return (callee.nativeProc(args), false, nil, @[])
  
  if callee.kind == vkType:
    let obj = objectValue(callee.typeNameVal)
    for i, arg in node.args:
      if i < callee.typeFields.len:
        obj.objFields[callee.typeFields[i]] = args[i]
    return (obj, false, nil, @[])
  
  if callee.kind != vkProc:
    vm.error("Cannot call " & typeName(callee), node.line, node.col)
  
  if args.len != callee.procParams.len:
    vm.error("Expected " & $callee.procParams.len & " arguments, got " & $args.len, node.line, node.col)
  
  # User-defined function - needs a frame
  return (nilValue(), true, callee, args)

proc evalExpr(vm: VM, node: Node): Value =
  ## Evaluate an expression (within a single step).
  ## Does NOT handle statements that create new frames.
  if node.isNil:
    return nilValue()
  
  case node.kind
  of nkIntLit:
    return intValue(node.intVal)
  of nkFloatLit:
    return floatValue(node.floatVal)
  of nkStrLit:
    return stringValue(node.strVal)
  of nkBoolLit:
    return boolValue(node.boolVal)
  of nkNilLit:
    return nilValue()
  of nkIdent:
    result = vm.currentScope.lookup(node.name)
    if result.isNil:
      vm.error(fmt"Undefined variable '{node.name}'", node.line, node.col)
  of nkBinaryOp:
    return vm.evalBinaryOp(node)
  of nkUnaryOp:
    return vm.evalUnaryOp(node)
  of nkCall:
    let (callResult, needsFrame, callee, args) = vm.evalCallExpr(node)
    if needsFrame:
      # This shouldn't happen during expression evaluation within step
      # But we handle it by executing the function synchronously
      let savedScope = vm.currentScope
      vm.currentScope = newScope(callee.procClosure)
      for i, param in callee.procParams:
        vm.currentScope.define(param, args[i])
      # Recursively evaluate (fallback for expressions with calls)
      var funcResult = vm.evalExpr(callee.procBody)
      if vm.controlFlow == cfReturn:
        funcResult = vm.returnValue
        vm.controlFlow = cfNone
        vm.returnValue = nil
      vm.currentScope = savedScope
      return funcResult
    return callResult
  of nkIndex:
    return vm.evalIndex(node)
  of nkDot:
    return vm.evalDot(node)
  of nkArray:
    var elems: seq[Value] = @[]
    for elem in node.arrayElems:
      elems.add(vm.evalExpr(elem))
    return arrayValue(elems)
  of nkTable:
    result = tableValue()
    for i in 0..<node.tableKeys.len:
      let key = vm.evalExpr(node.tableKeys[i])
      let val = vm.evalExpr(node.tableVals[i])
      if key.kind != vkString:
        vm.error("Table key must be a string", node.line, node.col)
      result.tableVal[key.strVal] = val
  of nkSet:
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
  of nkRange:
    let startVal = vm.evalExpr(node.rangeStart)
    let endVal = vm.evalExpr(node.rangeEnd)
    if startVal.kind != vkInt or endVal.kind != vkInt:
      vm.error("Range bounds must be integers", node.line, node.col)
    return rangeValue(startVal.intVal, endVal.intVal, node.rangeInclusive)
  of nkBlock:
    # Evaluate block as expression (returns last value)
    result = nilValue()
    for stmt in node.stmts:
      result = vm.evalExpr(stmt)
      if vm.controlFlow != cfNone:
        break
  of nkReturnStmt:
    if node.returnValue != nil:
      vm.returnValue = vm.evalExpr(node.returnValue)
    else:
      vm.returnValue = nilValue()
    vm.controlFlow = cfReturn
    return vm.returnValue
  
  of nkIfStmt:
    let cond = vm.evalExpr(node.ifCond)
    if isTruthy(cond):
      return vm.evalExpr(node.ifBody)
    
    for branch in node.elifBranches:
      let elifCond = vm.evalExpr(branch.elifCond)
      if isTruthy(elifCond):
        return vm.evalExpr(branch.elifBody)
    
    if node.elseBranch != nil:
      let elseNode = node.elseBranch
      if elseNode.kind == nkElseBranch:
        return vm.evalExpr(elseNode.elseBody)
      else:
        return vm.evalExpr(elseNode)
    
    return nilValue()
  
  of nkLetStmt:
    let value = vm.evalExpr(node.varValue)
    vm.currentScope.define(node.varName, value, isConst = true)
    return nilValue()
  
  of nkVarStmt:
    let value = vm.evalExpr(node.varValue)
    vm.currentScope.define(node.varName, value, isConst = false)
    return nilValue()
  
  of nkAssign:
    let value = vm.evalExpr(node.assignValue)
    if node.assignTarget.kind == nkIdent:
      discard vm.currentScope.assign(node.assignTarget.name, value)
    elif node.assignTarget.kind == nkIndex:
      let obj = vm.evalExpr(node.assignTarget.indexee)
      let index = vm.evalExpr(node.assignTarget.index)
      if obj.kind == vkArray:
        obj.arrayVal[index.intVal] = value
      elif obj.kind == vkTable:
        obj.tableVal[index.strVal] = value
    elif node.assignTarget.kind == nkDot:
      let obj = vm.evalExpr(node.assignTarget.dotLeft)
      if obj.kind == vkObject:
        obj.objFields[node.assignTarget.dotField] = value
    return nilValue()
  
  of nkForStmt:
    let iter = vm.evalExpr(node.forIter)
    var values: seq[Value] = @[]
    case iter.kind
    of vkRange:
      let s = iter.rangeStart
      let e = if iter.rangeInclusive: iter.rangeEnd else: iter.rangeEnd - 1
      for i in s..e:
        values.add(intValue(i))
    of vkArray:
      values = iter.arrayVal
    of vkString:
      for c in iter.strVal:
        values.add(stringValue($c))
    else:
      discard
    
    let savedScope = vm.currentScope
    for val in values:
      # Create new scope for each iteration (important for closures)
      vm.currentScope = newScope(savedScope)
      vm.currentScope.define(node.forVar, val)
      discard vm.evalExpr(node.forBody)
      if vm.controlFlow == cfBreak:
        vm.controlFlow = cfNone
        break
      if vm.controlFlow == cfContinue:
        vm.controlFlow = cfNone
      if vm.controlFlow == cfReturn:
        break
    vm.currentScope = savedScope
    return nilValue()
  
  of nkWhileStmt:
    let savedScope = vm.currentScope
    vm.currentScope = newScope(savedScope)
    while true:
      let cond = vm.evalExpr(node.whileCond)
      if not isTruthy(cond):
        break
      discard vm.evalExpr(node.whileBody)
      if vm.controlFlow == cfBreak:
        vm.controlFlow = cfNone
        break
      if vm.controlFlow == cfContinue:
        vm.controlFlow = cfNone
      if vm.controlFlow == cfReturn:
        break
    vm.currentScope = savedScope
    return nilValue()
  
  of nkBreakStmt:
    vm.controlFlow = cfBreak
    return nilValue()
  
  of nkContinueStmt:
    vm.controlFlow = cfContinue
    return nilValue()
  
  of nkProcDef:
    let procVal = procValue(node.procName, node.procParams, node.procBody, vm.currentScope)
    vm.currentScope.define(node.procName, procVal)
    return nilValue()
  
  of nkTypeDef:
    var fields: seq[string] = @[]
    if node.typeBody.kind == nkObjectDef:
      for field in node.typeBody.objectFields:
        fields.add(field.fieldName)
    let typeVal = typeValue(node.typeName, fields)
    vm.currentScope.define(node.typeName, typeVal)
    return nilValue()
  
  of nkEchoStmt:
    var parts: seq[string] = @[]
    for arg in node.echoArgs:
      parts.add($vm.evalExpr(arg))
    vm.output.add(parts.join(" "))
    return nilValue()
  
  else:
    return nilValue()

# =============================================================================
# Statement Execution (used by step)
# =============================================================================

proc execAssign(vm: VM, node: Node) =
  let value = vm.evalExpr(node.assignValue)
  
  if node.assignTarget.kind == nkIdent:
    let name = node.assignTarget.name
    if vm.currentScope.isConstant(name):
      vm.error(fmt"Cannot assign to constant '{name}'", node.line, node.col)
    if not vm.currentScope.assign(name, value):
      vm.error(fmt"Undefined variable '{name}'", node.line, node.col)
    return
  
  if node.assignTarget.kind == nkIndex:
    let obj = vm.evalExpr(node.assignTarget.indexee)
    let index = vm.evalExpr(node.assignTarget.index)
    
    if obj.kind == vkArray:
      if index.kind != vkInt:
        vm.error("Array index must be an integer", node.line, node.col)
      let i = index.intVal
      if i < 0 or i >= obj.arrayVal.len:
        vm.error(fmt"Array index {i} out of bounds", node.line, node.col)
      obj.arrayVal[i] = value
      return
    
    if obj.kind == vkTable:
      if index.kind != vkString:
        vm.error("Table key must be a string", node.line, node.col)
      obj.tableVal[index.strVal] = value
      return
    
    vm.error(fmt"Cannot index assign {typeName(obj)}", node.line, node.col)
  
  if node.assignTarget.kind == nkDot:
    let obj = vm.evalExpr(node.assignTarget.dotLeft)
    if obj.kind == vkObject:
      obj.objFields[node.assignTarget.dotField] = value
      return
    vm.error(fmt"Cannot assign field of {typeName(obj)}", node.line, node.col)
  
  vm.error("Invalid assignment target", node.line, node.col)

proc execProcDef(vm: VM, node: Node) =
  let procVal = procValue(node.procName, node.procParams, node.procBody, vm.currentScope)
  vm.currentScope.define(node.procName, procVal)

proc execTypeDef(vm: VM, node: Node) =
  var fields: seq[string] = @[]
  if node.typeBody.kind == nkObjectDef:
    for field in node.typeBody.objectFields:
      fields.add(field.fieldName)
  let typeVal = typeValue(node.typeName, fields)
  vm.currentScope.define(node.typeName, typeVal)

proc execEcho(vm: VM, node: Node) =
  var parts: seq[string] = @[]
  for arg in node.echoArgs:
    parts.add($vm.evalExpr(arg))
  vm.output.add(parts.join(" "))

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
    if frame.kind == fkFunction:
      vm.currentScope = frame.returnToScope

proc currentFrame(vm: VM): ExecutionFrame =
  if vm.frames.len > 0:
    return vm.frames[^1]
  return nil

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
  of fkForLoop:
    frame.forIndex += 1
    if frame.forIndex >= frame.forValues.len:
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
      iterScope.define(frame.forNode.forVar, frame.forValues[frame.forIndex])
      frame.scope = iterScope
      vm.currentScope = iterScope
      vm.updateLine()
  
  of fkWhileLoop:
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
  
  of fkFunction:
    # Handle return value assignment if needed
    let returnVal = if vm.returnValue != nil: vm.returnValue else: nilValue()
    let varName = frame.returnVarName
    let varIsConst = frame.returnVarIsConst
    let assignTarget = frame.returnAssignTarget
    
    vm.popFrame()
    
    # Assign return value if we have a target
    if varName != "":
      vm.currentScope.define(varName, returnVal, isConst = varIsConst)
    elif assignTarget != nil:
      # Handle assignment target (for cases like x = foo())
      if assignTarget.kind == nkIdent:
        discard vm.currentScope.assign(assignTarget.name, returnVal)
    
    vm.returnValue = nil
    
    if vm.frames.len == 0:
      vm.isFinished = true
    else:
      vm.updateLine()
  
  of fkBlock:
    vm.popFrame()
    if vm.frames.len == 0:
      vm.isFinished = true
    else:
      vm.updateLine()

proc load*(vm: VM, ast: Node) =
  ## Load an AST for step-by-step execution.
  vm.frames = @[]
  vm.isFinished = false
  vm.controlFlow = cfNone
  vm.returnValue = nil
  vm.currentScope = vm.globalScope
  
  var stmts: seq[Node] = @[]
  if ast.kind == nkProgram:
    stmts = ast.stmts
  elif ast.kind == nkBlock:
    stmts = ast.stmts
  else:
    stmts = @[ast]
  
  if stmts.len == 0:
    vm.isFinished = true
    vm.currentLine = 0
    return
  
  vm.pushFrame(fkBlock, stmts, vm.globalScope)
  vm.currentLine = stmts[0].line

proc step*(vm: VM) =
  ## Execute one statement and advance to the next.
  if vm.isFinished or vm.frames.len == 0:
    vm.isFinished = true
    return
  
  let frame = vm.currentFrame
  
  # Handle completed frames (shouldn't happen, but be safe)
  if frame.stmtIndex >= frame.stmts.len:
    vm.advanceFrame()
    return
  
  let stmt = frame.stmts[frame.stmtIndex]
  vm.currentScope = frame.scope
  
  case stmt.kind
  of nkLetStmt, nkVarStmt:
    let isConst = stmt.kind == nkLetStmt
    let varName = stmt.varName
    let valueNode = stmt.varValue
    
    # Check if the value is a function call
    if valueNode != nil and valueNode.kind == nkCall:
      let (callResult, needsFrame, callee, args) = vm.evalCallExpr(valueNode)
      if needsFrame:
        # Push function frame, store where to assign result
        let savedScope = vm.currentScope
        let funcScope = newScope(callee.procClosure)
        vm.currentScope = funcScope
        
        for i, param in callee.procParams:
          funcScope.define(param, args[i])
        
        var bodyStmts: seq[Node] = @[]
        if callee.procBody.kind == nkBlock:
          bodyStmts = callee.procBody.stmts
        else:
          bodyStmts = @[callee.procBody]
        
        let funcFrame = ExecutionFrame(
          kind: fkFunction,
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
        vm.currentScope.define(varName, callResult, isConst = isConst)
    else:
      # Normal expression
      let value = vm.evalExpr(valueNode)
      vm.currentScope.define(varName, value, isConst = isConst)
    
    frame.stmtIndex += 1
    vm.updateLine()
  
  of nkAssign:
    let valueNode = stmt.assignValue
    
    # Check if the value is a function call
    if valueNode != nil and valueNode.kind == nkCall:
      let (callResult, needsFrame, callee, args) = vm.evalCallExpr(valueNode)
      if needsFrame:
        # Push function frame, store where to assign result
        let savedScope = vm.currentScope
        let funcScope = newScope(callee.procClosure)
        vm.currentScope = funcScope
        
        for i, param in callee.procParams:
          funcScope.define(param, args[i])
        
        var bodyStmts: seq[Node] = @[]
        if callee.procBody.kind == nkBlock:
          bodyStmts = callee.procBody.stmts
        else:
          bodyStmts = @[callee.procBody]
        
        let funcFrame = ExecutionFrame(
          kind: fkFunction,
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
        let target = stmt.assignTarget
        if target.kind == nkIdent:
          discard vm.currentScope.assign(target.name, callResult)
        elif target.kind == nkIndex:
          let obj = vm.evalExpr(target.indexee)
          let index = vm.evalExpr(target.index)
          if obj.kind == vkArray:
            obj.arrayVal[index.intVal] = callResult
          elif obj.kind == vkTable:
            obj.tableVal[index.strVal] = callResult
        elif target.kind == nkDot:
          let obj = vm.evalExpr(target.dotLeft)
          if obj.kind == vkObject:
            obj.objFields[target.dotField] = callResult
    else:
      vm.execAssign(stmt)
    
    frame.stmtIndex += 1
    vm.updateLine()
  
  of nkProcDef:
    vm.execProcDef(stmt)
    frame.stmtIndex += 1
    vm.updateLine()
  
  of nkTypeDef:
    vm.execTypeDef(stmt)
    frame.stmtIndex += 1
    vm.updateLine()
  
  of nkEchoStmt:
    vm.execEcho(stmt)
    frame.stmtIndex += 1
    vm.updateLine()
  
  of nkIfStmt:
    let cond = vm.evalExpr(stmt.ifCond)
    frame.stmtIndex += 1
    
    var bodyStmts: seq[Node] = @[]
    var foundBranch = false
    
    if isTruthy(cond):
      if stmt.ifBody.kind == nkBlock:
        bodyStmts = stmt.ifBody.stmts
      else:
        bodyStmts = @[stmt.ifBody]
      foundBranch = true
    else:
      for branch in stmt.elifBranches:
        let elifCond = vm.evalExpr(branch.elifCond)
        if isTruthy(elifCond):
          if branch.elifBody.kind == nkBlock:
            bodyStmts = branch.elifBody.stmts
          else:
            bodyStmts = @[branch.elifBody]
          foundBranch = true
          break
      
      if not foundBranch and stmt.elseBranch != nil:
        let elseNode = stmt.elseBranch
        var elseBodyNode: Node
        if elseNode.kind == nkElseBranch:
          elseBodyNode = elseNode.elseBody
        else:
          elseBodyNode = elseNode  # Direct body node
        
        if elseBodyNode.kind == nkBlock:
          bodyStmts = elseBodyNode.stmts
        else:
          bodyStmts = @[elseBodyNode]
        foundBranch = true
    
    if foundBranch and bodyStmts.len > 0:
      let newScope = newScope(vm.currentScope)
      vm.currentScope = newScope
      vm.pushFrame(fkBlock, bodyStmts, newScope)
    
    vm.updateLine()
  
  of nkForStmt:
    let iter = vm.evalExpr(stmt.forIter)
    frame.stmtIndex += 1
    
    var values: seq[Value] = @[]
    case iter.kind
    of vkRange:
      let s = iter.rangeStart
      let e = if iter.rangeInclusive: iter.rangeEnd else: iter.rangeEnd - 1
      for i in s..e:
        values.add(intValue(i))
    of vkArray:
      values = iter.arrayVal
    of vkString:
      for c in iter.strVal:
        values.add(stringValue($c))
    else:
      vm.error("Cannot iterate over " & typeName(iter), stmt.line, stmt.col)
    
    if values.len > 0:
      var bodyStmts: seq[Node] = @[]
      if stmt.forBody.kind == nkBlock:
        bodyStmts = stmt.forBody.stmts
      else:
        bodyStmts = @[stmt.forBody]
      
      let newScope = newScope(vm.currentScope)
      vm.currentScope = newScope
      newScope.define(stmt.forVar, values[0])
      
      let loopFrame = ExecutionFrame(
        kind: fkForLoop,
        stmts: bodyStmts,
        stmtIndex: 0,
        scope: newScope,
        forNode: stmt,
        forValues: values,
        forIndex: 0
      )
      vm.frames.add(loopFrame)
    
    vm.updateLine()
  
  of nkWhileStmt:
    let cond = vm.evalExpr(stmt.whileCond)
    frame.stmtIndex += 1  # Advance past while statement before entering loop
    
    if isTruthy(cond):
      var bodyStmts: seq[Node] = @[]
      if stmt.whileBody.kind == nkBlock:
        bodyStmts = stmt.whileBody.stmts
      else:
        bodyStmts = @[stmt.whileBody]
      
      let newScope = newScope(vm.currentScope)
      vm.currentScope = newScope
      
      let loopFrame = ExecutionFrame(
        kind: fkWhileLoop,
        stmts: bodyStmts,
        stmtIndex: 0,
        scope: newScope,
        whileNode: stmt
      )
      vm.frames.add(loopFrame)
      vm.updateLine()
    else:
      vm.updateLine()
  
  of nkReturnStmt:
    if stmt.returnValue != nil:
      vm.returnValue = vm.evalExpr(stmt.returnValue)
    else:
      vm.returnValue = nilValue()
    
    # Pop frames until we exit the function, handling return value
    while vm.frames.len > 0:
      let f = vm.currentFrame
      if f.kind == fkFunction:
        # Handle return value assignment
        let returnVal = if vm.returnValue != nil: vm.returnValue else: nilValue()
        let varName = f.returnVarName
        let varIsConst = f.returnVarIsConst
        let assignTarget = f.returnAssignTarget
        
        vm.popFrame()
        
        # Assign return value if we have a target
        if varName != "":
          vm.currentScope.define(varName, returnVal, isConst = varIsConst)
        elif assignTarget != nil:
          if assignTarget.kind == nkIdent:
            discard vm.currentScope.assign(assignTarget.name, returnVal)
        
        vm.returnValue = nil
        break
      else:
        vm.popFrame()
    
    if vm.frames.len == 0:
      vm.isFinished = true
    else:
      vm.updateLine()
  
  of nkBreakStmt:
    # Pop frames until we exit the loop
    while vm.frames.len > 0:
      let f = vm.currentFrame
      vm.popFrame()
      if f.kind in {fkForLoop, fkWhileLoop}:
        break
    
    if vm.frames.len == 0:
      vm.isFinished = true
    else:
      # Note: stmtIndex was already incremented when we set up the loop
      vm.updateLine()
  
  of nkContinueStmt:
    # Pop frames until we reach the loop
    while vm.frames.len > 0:
      let f = vm.currentFrame
      if f.kind in {fkForLoop, fkWhileLoop}:
        f.stmtIndex = f.stmts.len  # Will trigger next iteration check
        break
      vm.popFrame()
    
    vm.updateLine()
  
  of nkCall:
    let (_, needsFrame, callee, args) = vm.evalCallExpr(stmt)
    
    if needsFrame:
      # Push function frame
      let savedScope = vm.currentScope
      let funcScope = newScope(callee.procClosure)
      vm.currentScope = funcScope
      
      for i, param in callee.procParams:
        funcScope.define(param, args[i])
      
      var bodyStmts: seq[Node] = @[]
      if callee.procBody.kind == nkBlock:
        bodyStmts = callee.procBody.stmts
      else:
        bodyStmts = @[callee.procBody]
      
      let funcFrame = ExecutionFrame(
        kind: fkFunction,
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
    if frame.kind == fkFunction:
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
# Utility Functions
# =============================================================================

proc addProc*(vm: VM, name: string, p: NativeProc) =
  vm.globalScope.define(name, nativeProcValue(name, p))

proc getOutput*(vm: VM): string =
  vm.output.join("\n")

proc clearOutput*(vm: VM) =
  vm.output = @[]
