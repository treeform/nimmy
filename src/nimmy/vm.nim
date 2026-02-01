## nimmy_vm.nim
## Virtual Machine for the Nimmy scripting language

import types
import utils
import std/[strformat, tables, strutils]

type
  ControlFlow = enum
    cfNone,
    cfBreak,
    cfContinue,
    cfReturn

  VM* = ref object
    globalScope*: Scope
    currentScope*: Scope
    output*: seq[string]
    debugInfo*: DebugInfo
    controlFlow: ControlFlow
    returnValue: Value

proc newVM*(): VM =
  let global = newScope()
  VM(
    globalScope: global,
    currentScope: global,
    output: @[],
    debugInfo: DebugInfo(),
    controlFlow: cfNone,
    returnValue: nil
  )

proc pushScope(vm: VM) =
  vm.currentScope = newScope(vm.currentScope)

proc popScope(vm: VM) =
  if vm.currentScope.parent != nil:
    vm.currentScope = vm.currentScope.parent

proc error(vm: VM, msg: string, line, col: int) =
  var e = newException(RuntimeError, fmt"{msg} at line {line}, column {col}")
  e.line = line
  e.col = col
  raise e

# Forward declaration
proc eval*(vm: VM, node: Node): Value

proc evalBinaryOp(vm: VM, node: Node): Value =
  let left = vm.eval(node.binLeft)
  
  # Short-circuit evaluation for and/or
  if node.binOp == "and":
    if not isTruthy(left):
      return boolValue(false)
    return boolValue(isTruthy(vm.eval(node.binRight)))
  
  if node.binOp == "or":
    if isTruthy(left):
      return boolValue(true)
    return boolValue(isTruthy(vm.eval(node.binRight)))
  
  let right = vm.eval(node.binRight)
  
  case node.binOp
  of "+":
    if left.kind == vkInt and right.kind == vkInt:
      return intValue(left.intVal + right.intVal)
    if left.kind in {vkInt, vkFloat} and right.kind in {vkInt, vkFloat}:
      return floatValue(toFloat(left) + toFloat(right))
    if left.kind == vkSet and right.kind == vkSet:
      # Set union
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
      # Set difference
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
      # Set intersection
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
      let divisor = toFloat(right)
      if divisor == 0.0:
        vm.error("Division by zero", node.line, node.col)
      return floatValue(toFloat(left) / divisor)
    vm.error(fmt"Cannot divide {typeName(left)} by {typeName(right)}", node.line, node.col)
  
  of "%":
    if left.kind == vkInt and right.kind == vkInt:
      if right.intVal == 0:
        vm.error("Modulo by zero", node.line, node.col)
      return intValue(left.intVal mod right.intVal)
    vm.error(fmt"Cannot modulo {typeName(left)} and {typeName(right)}", node.line, node.col)
  
  of "&":
    # String concatenation
    return stringValue($left & $right)
  
  of "==":
    return boolValue(equals(left, right))
  
  of "!=":
    return boolValue(not equals(left, right))
  
  of "<":
    return boolValue(compare(left, right) < 0)
  
  of "<=":
    return boolValue(compare(left, right) <= 0)
  
  of ">":
    return boolValue(compare(left, right) > 0)
  
  of ">=":
    return boolValue(compare(left, right) >= 0)
  of "in":
    if right.kind == vkSet:
      return boolValue(setContains(right, left))
    if right.kind == vkArray:
      for elem in right.arrayVal:
        if equals(elem, left):
          return boolValue(true)
      return boolValue(false)
    if right.kind == vkTable:
      if left.kind != vkString:
        vm.error("Table key must be a string", node.line, node.col)
      return boolValue(right.tableVal.hasKey(left.strVal))
    if right.kind == vkString:
      if left.kind != vkString:
        vm.error("Can only check string containment in string", node.line, node.col)
      return boolValue(left.strVal in right.strVal)
    vm.error("Cannot use 'in' with " & typeName(right), node.line, node.col)
  else:
    vm.error("Unknown operator '" & node.binOp & "'", node.line, node.col)

proc evalUnaryOp(vm: VM, node: Node): Value =
  let operand = vm.eval(node.unOperand)
  
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
    vm.error("Unknown unary operator '" & node.unOp & "'", node.line, node.col)

proc evalCall(vm: VM, node: Node): Value =
  var callee: Value
  var args: seq[Value] = @[]
  var ufcsReceiver: Value = nil
  
  # Check for UFCS: a.func(b) -> func(a, b)
  if node.callee.kind == nkDot:
    let receiver = vm.eval(node.callee.dotLeft)
    let methodName = node.callee.dotField
    # Try to find a function with this name
    let maybeFunc = vm.currentScope.lookup(methodName)
    if maybeFunc != nil and maybeFunc.kind in {vkProc, vkNativeProc}:
      callee = maybeFunc
      ufcsReceiver = receiver
    elif receiver.kind == vkObject and receiver.objFields.hasKey(methodName):
      # It's a method stored in the object
      callee = receiver.objFields[methodName]
    else:
      # Fall back to regular evaluation (might error)
      callee = vm.eval(node.callee)
  else:
    callee = vm.eval(node.callee)
  
  # Build args, prepending UFCS receiver if present
  if ufcsReceiver != nil:
    args.add(ufcsReceiver)
  for arg in node.args:
    args.add(vm.eval(arg))
  
  if callee.kind == vkNativeProc:
    return callee.nativeProc(args)
  
  if callee.kind == vkType:
    # Constructor call
    let obj = objectValue(callee.typeNameVal)
    # Process named arguments
    for i, arg in node.args:
      if i < callee.typeFields.len:
        obj.objFields[callee.typeFields[i]] = args[i]
    return obj
  
  if callee.kind != vkProc:
    vm.error("Cannot call " & typeName(callee), node.line, node.col)
  
  if args.len != callee.procParams.len:
    vm.error("Expected " & $callee.procParams.len & " arguments, got " & $args.len, node.line, node.col)
  
  # Create new scope with closure as parent
  let savedScope = vm.currentScope
  vm.currentScope = newScope(callee.procClosure)
  
  # Bind parameters
  for i, param in callee.procParams:
    vm.currentScope.define(param, args[i])
  
  # Execute body
  result = vm.eval(callee.procBody)
  
  # Handle return value
  if vm.controlFlow == cfReturn:
    result = vm.returnValue
    vm.controlFlow = cfNone
    vm.returnValue = nil
  
  vm.currentScope = savedScope

proc evalIndex(vm: VM, node: Node): Value =
  let obj = vm.eval(node.indexee)
  let index = vm.eval(node.index)
  
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
  let obj = vm.eval(node.dotLeft)
  
  if obj.kind == vkObject:
    if obj.objFields.hasKey(node.dotField):
      return obj.objFields[node.dotField]
    # Try UFCS for objects
    let maybeFunc = vm.currentScope.lookup(node.dotField)
    if maybeFunc != nil and maybeFunc.kind in {vkProc, vkNativeProc}:
      # Call the function with obj as the first argument
      if maybeFunc.kind == vkNativeProc:
        return maybeFunc.nativeProc(@[obj])
      if maybeFunc.procParams.len == 1:
        let savedScope = vm.currentScope
        vm.currentScope = newScope(maybeFunc.procClosure)
        vm.currentScope.define(maybeFunc.procParams[0], obj)
        result = vm.eval(maybeFunc.procBody)
        if vm.controlFlow == cfReturn:
          result = vm.returnValue
          vm.controlFlow = cfNone
          vm.returnValue = nil
        vm.currentScope = savedScope
        return result
    vm.error("Object has no field '" & node.dotField & "'", node.line, node.col)
  
  # Built-in properties
  if obj.kind == vkArray:
    if node.dotField == "len":
      return intValue(obj.arrayVal.len)
  
  if obj.kind == vkString:
    if node.dotField == "len":
      return intValue(obj.strVal.len)
  
  # UFCS: try to find a function with this name
  let maybeFunc = vm.currentScope.lookup(node.dotField)
  if maybeFunc != nil and maybeFunc.kind in {vkProc, vkNativeProc}:
    # Call the function with obj as the first argument
    if maybeFunc.kind == vkNativeProc:
      return maybeFunc.nativeProc(@[obj])
    if maybeFunc.procParams.len == 1:
      let savedScope = vm.currentScope
      vm.currentScope = newScope(maybeFunc.procClosure)
      vm.currentScope.define(maybeFunc.procParams[0], obj)
      result = vm.eval(maybeFunc.procBody)
      if vm.controlFlow == cfReturn:
        result = vm.returnValue
        vm.controlFlow = cfNone
        vm.returnValue = nil
      vm.currentScope = savedScope
      return result
  
  vm.error("Cannot access field of " & typeName(obj), node.line, node.col)

proc evalBlock(vm: VM, node: Node): Value =
  result = nilValue()
  for stmt in node.stmts:
    result = vm.eval(stmt)
    if vm.controlFlow != cfNone:
      break

proc evalIf(vm: VM, node: Node): Value =
  result = nilValue()
  
  let cond = vm.eval(node.ifCond)
  if isTruthy(cond):
    vm.pushScope()
    result = vm.eval(node.ifBody)
    vm.popScope()
    return result
  
  for branch in node.elifBranches:
    let elifCond = vm.eval(branch.elifCond)
    if isTruthy(elifCond):
      vm.pushScope()
      result = vm.eval(branch.elifBody)
      vm.popScope()
      return result
  
  if node.elseBranch != nil:
    vm.pushScope()
    result = vm.eval(node.elseBranch)
    vm.popScope()

proc evalFor(vm: VM, node: Node): Value =
  result = nilValue()
  let iter = vm.eval(node.forIter)
  if iter.kind == vkRange:
    var i = iter.rangeStart
    let endVal = iter.rangeEnd
    let inclusive = iter.rangeInclusive
    while (inclusive and i <= endVal) or (not inclusive and i < endVal):
      vm.pushScope()
      vm.currentScope.define(node.forVar, intValue(i))
      result = vm.eval(node.forBody)
      vm.popScope()
      if vm.controlFlow == cfBreak:
        vm.controlFlow = cfNone
        break
      if vm.controlFlow == cfContinue:
        vm.controlFlow = cfNone
      if vm.controlFlow == cfReturn:
        break
      i += 1
  elif iter.kind == vkArray:
    for elem in iter.arrayVal:
      vm.pushScope()
      vm.currentScope.define(node.forVar, elem)
      result = vm.eval(node.forBody)
      vm.popScope()
      if vm.controlFlow == cfBreak:
        vm.controlFlow = cfNone
        break
      if vm.controlFlow == cfContinue:
        vm.controlFlow = cfNone
      if vm.controlFlow == cfReturn:
        break
  elif iter.kind == vkString:
    for c in iter.strVal:
      vm.pushScope()
      vm.currentScope.define(node.forVar, stringValue($c))
      result = vm.eval(node.forBody)
      vm.popScope()
      if vm.controlFlow == cfBreak:
        vm.controlFlow = cfNone
        break
      if vm.controlFlow == cfContinue:
        vm.controlFlow = cfNone
      if vm.controlFlow == cfReturn:
        break
  else:
    vm.error("Cannot iterate over " & typeName(iter), node.line, node.col)

proc evalWhile(vm: VM, node: Node): Value =
  result = nilValue()
  
  vm.pushScope()
  while isTruthy(vm.eval(node.whileCond)):
    result = vm.eval(node.whileBody)
    
    if vm.controlFlow == cfBreak:
      vm.controlFlow = cfNone
      break
    if vm.controlFlow == cfContinue:
      vm.controlFlow = cfNone
    if vm.controlFlow == cfReturn:
      break
  
  vm.popScope()

proc evalAssign(vm: VM, node: Node): Value =
  let value = vm.eval(node.assignValue)
  
  if node.assignTarget.kind == nkIdent:
    let name = node.assignTarget.name
    if vm.currentScope.isConstant(name):
      vm.error(fmt"Cannot assign to constant '{name}'", node.line, node.col)
    if not vm.currentScope.assign(name, value):
      vm.error(fmt"Undefined variable '{name}'", node.line, node.col)
    return value
  
  if node.assignTarget.kind == nkIndex:
    let obj = vm.eval(node.assignTarget.indexee)
    let index = vm.eval(node.assignTarget.index)
    
    if obj.kind == vkArray:
      if index.kind != vkInt:
        vm.error("Array index must be an integer", node.line, node.col)
      let i = index.intVal
      if i < 0 or i >= obj.arrayVal.len:
        vm.error(fmt"Array index {i} out of bounds", node.line, node.col)
      obj.arrayVal[i] = value
      return value
    
    if obj.kind == vkTable:
      if index.kind != vkString:
        vm.error("Table key must be a string", node.line, node.col)
      obj.tableVal[index.strVal] = value
      return value
    
    vm.error(fmt"Cannot index assign {typeName(obj)}", node.line, node.col)
  
  if node.assignTarget.kind == nkDot:
    let obj = vm.eval(node.assignTarget.dotLeft)
    if obj.kind == vkObject:
      obj.objFields[node.assignTarget.dotField] = value
      return value
    vm.error(fmt"Cannot assign field of {typeName(obj)}", node.line, node.col)
  
  vm.error("Invalid assignment target", node.line, node.col)

proc eval*(vm: VM, node: Node): Value =
  if node.isNil:
    return nilValue()
  
  case node.kind
  of nkIntLit:
    result = intValue(node.intVal)
  
  of nkFloatLit:
    result = floatValue(node.floatVal)
  
  of nkStrLit:
    result = stringValue(node.strVal)
  
  of nkBoolLit:
    result = boolValue(node.boolVal)
  
  of nkNilLit:
    result = nilValue()
  
  of nkIdent:
    result = vm.currentScope.lookup(node.name)
    if result.isNil:
      vm.error(fmt"Undefined variable '{node.name}'", node.line, node.col)
  
  of nkBinaryOp:
    result = vm.evalBinaryOp(node)
  
  of nkUnaryOp:
    result = vm.evalUnaryOp(node)
  
  of nkCall:
    result = vm.evalCall(node)
  
  of nkIndex:
    result = vm.evalIndex(node)
  
  of nkDot:
    result = vm.evalDot(node)
  
  of nkLetStmt:
    let value = vm.eval(node.varValue)
    vm.currentScope.define(node.varName, value, isConst = true)
    result = value
  
  of nkVarStmt:
    let value = vm.eval(node.varValue)
    vm.currentScope.define(node.varName, value, isConst = false)
    result = value
  
  of nkAssign:
    result = vm.evalAssign(node)
  
  of nkIfStmt:
    result = vm.evalIf(node)
  
  of nkElifBranch:
    result = nilValue()  # Handled by evalIf
  
  of nkElseBranch:
    result = vm.eval(node.elseBody)
  
  of nkForStmt:
    result = vm.evalFor(node)
  
  of nkWhileStmt:
    result = vm.evalWhile(node)
  
  of nkBreakStmt:
    vm.controlFlow = cfBreak
    result = nilValue()
  
  of nkContinueStmt:
    vm.controlFlow = cfContinue
    result = nilValue()
  
  of nkReturnStmt:
    if node.returnValue != nil:
      vm.returnValue = vm.eval(node.returnValue)
    else:
      vm.returnValue = nilValue()
    vm.controlFlow = cfReturn
    result = vm.returnValue
  
  of nkProcDef:
    let procVal = procValue(node.procName, node.procParams, node.procBody, vm.currentScope)
    vm.currentScope.define(node.procName, procVal)
    result = procVal
  
  of nkTypeDef:
    var fields: seq[string] = @[]
    if node.typeBody.kind == nkObjectDef:
      for field in node.typeBody.objectFields:
        fields.add(field.fieldName)
    let typeVal = typeValue(node.typeName, fields)
    vm.currentScope.define(node.typeName, typeVal)
    result = typeVal
  
  of nkObjectDef:
    result = nilValue()  # Handled by nkTypeDef
  
  of nkFieldDef:
    result = nilValue()  # Handled by nkTypeDef
  
  of nkBlock, nkProgram:
    result = vm.evalBlock(node)
  
  of nkEchoStmt:
    var parts: seq[string] = @[]
    for arg in node.echoArgs:
      parts.add($vm.eval(arg))
    let output = parts.join(" ")
    vm.output.add(output)
    result = nilValue()
  
  of nkArray:
    var elems: seq[Value] = @[]
    for elem in node.arrayElems:
      elems.add(vm.eval(elem))
    result = arrayValue(elems)
  
  of nkTable:
    result = tableValue()
    for i in 0..<node.tableKeys.len:
      let key = vm.eval(node.tableKeys[i])
      let val = vm.eval(node.tableVals[i])
      if key.kind != vkString:
        vm.error("Table key must be a string", node.line, node.col)
      result.tableVal[key.strVal] = val
  of nkSet:
    var elems: seq[Value] = @[]
    for elem in node.setElems:
      let val = vm.eval(elem)
      # Only add if not already in set
      var found = false
      for existing in elems:
        if equals(existing, val):
          found = true
          break
      if not found:
        elems.add(val)
    result = setValue(elems)
  of nkRange:
    let startVal = vm.eval(node.rangeStart)
    let endVal = vm.eval(node.rangeEnd)
    if startVal.kind != vkInt or endVal.kind != vkInt:
      vm.error("Range bounds must be integers", node.line, node.col)
    result = rangeValue(startVal.intVal, endVal.intVal, node.rangeInclusive)
  
  of nkEmpty:
    result = nilValue()

# Add a native procedure
proc addProc*(vm: VM, name: string, p: NativeProc) =
  vm.globalScope.define(name, nativeProcValue(name, p))

# Get output as string
proc getOutput*(vm: VM): string =
  vm.output.join("\n")

# Clear output
proc clearOutput*(vm: VM) =
  vm.output = @[]
