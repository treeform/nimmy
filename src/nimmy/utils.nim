## nimmy_utils.nim
## Utility functions for the Nimmy scripting language

import types
import std/[strformat, strutils, tables]

# Forward declarations
proc valueRepr*(v: Value): string
proc typeName*(v: Value): string

# Convert Value to string for display
proc `$`*(v: Value): string =
  if v.isNil:
    return "nil"
  case v.kind
  of NilValue:
    result = "nil"
  of BoolValue:
    result = $v.boolVal
  of IntValue:
    result = $v.intVal
  of FloatValue:
    result = $v.floatVal
  of StringValue:
    result = v.strVal
  of ArrayValue:
    var parts: seq[string]
    for elem in v.arrayVal:
      parts.add(valueRepr(elem))
    result = "[" & parts.join(", ") & "]"
  of TableValue:
    var parts: seq[string]
    for k, val in v.tableVal:
      parts.add("\"" & k & "\": " & valueRepr(val))
    result = "{" & parts.join(", ") & "}"
  of SetValue:
    var parts: seq[string]
    for elem in v.setVal:
      parts.add(valueRepr(elem))
    result = "{" & parts.join(", ") & "}"
  of ObjectValue:
    var parts: seq[string]
    for k, val in v.objFields:
      parts.add(fmt"{k}: {valueRepr(val)}")
    result = fmt"{v.objType}(" & parts.join(", ") & ")"
  of ProcValue:
    result = fmt"<proc {v.procName}>"
  of NativeProcValue:
    result = fmt"<native proc {v.nativeName}>"
  of TypeValue:
    result = fmt"<type {v.typeNameVal}>"
  of RangeValue:
    if v.rangeInclusive:
      result = fmt"{v.rangeStart}..{v.rangeEnd}"
    else:
      result = fmt"{v.rangeStart}..<{v.rangeEnd}"

# Debug representation (shows quotes around strings)
proc valueRepr*(v: Value): string =
  if v.isNil:
    return "nil"
  case v.kind
  of StringValue:
    "\"" & v.strVal & "\""
  else:
    $v

# Truthiness check
proc isTruthy*(v: Value): bool =
  if v.isNil:
    return false
  case v.kind
  of NilValue:
    result = false
  of BoolValue:
    result = v.boolVal
  of IntValue:
    result = v.intVal != 0
  of FloatValue:
    result = v.floatVal != 0.0
  of StringValue:
    result = v.strVal.len > 0
  of ArrayValue:
    result = v.arrayVal.len > 0
  of TableValue:
    result = v.tableVal.len > 0
  of SetValue:
    result = v.setVal.len > 0
  of ObjectValue:
    result = true
  of ProcValue, NativeProcValue, TypeValue:
    result = true
  of RangeValue:
    result = true

# Equality check
proc equals*(a, b: Value): bool =
  if a.isNil and b.isNil:
    return true
  if a.isNil or b.isNil:
    return false
  if a.kind != b.kind:
    # Allow int/float comparison
    if a.kind == IntValue and b.kind == FloatValue:
      return a.intVal.float64 == b.floatVal
    if a.kind == FloatValue and b.kind == IntValue:
      return a.floatVal == b.intVal.float64
    return false
  case a.kind
  of NilValue:
    result = true
  of BoolValue:
    result = a.boolVal == b.boolVal
  of IntValue:
    result = a.intVal == b.intVal
  of FloatValue:
    result = a.floatVal == b.floatVal
  of StringValue:
    result = a.strVal == b.strVal
  of ArrayValue:
    if a.arrayVal.len != b.arrayVal.len:
      return false
    for i in 0..<a.arrayVal.len:
      if not equals(a.arrayVal[i], b.arrayVal[i]):
        return false
    result = true
  of SetValue:
    if a.setVal.len != b.setVal.len:
      return false
    # Check that all elements in a are in b
    for elem in a.setVal:
      var found = false
      for other in b.setVal:
        if equals(elem, other):
          found = true
          break
      if not found:
        return false
    result = true
  else:
    # Reference equality for other types
    result = a == b

# Comparison (for < > <= >=)
proc compare*(a, b: Value): int =
  ## Returns -1 if a < b, 0 if a == b, 1 if a > b
  if a.kind == IntValue and b.kind == IntValue:
    return cmp(a.intVal, b.intVal)
  if a.kind == FloatValue and b.kind == FloatValue:
    return cmp(a.floatVal, b.floatVal)
  if a.kind == IntValue and b.kind == FloatValue:
    return cmp(a.intVal.float64, b.floatVal)
  if a.kind == FloatValue and b.kind == IntValue:
    return cmp(a.floatVal, b.intVal.float64)
  if a.kind == StringValue and b.kind == StringValue:
    return cmp(a.strVal, b.strVal)
  raise newException(RuntimeError, "Cannot compare " & typeName(a) & " and " & typeName(b))

# Convert Value to float for arithmetic
proc toFloat*(v: Value): float64 =
  case v.kind
  of IntValue:
    result = v.intVal.float64
  of FloatValue:
    result = v.floatVal
  else:
    raise newException(RuntimeError, fmt"Cannot convert {v.kind} to float")

# Convert Value to int
proc toInt*(v: Value): int64 =
  case v.kind
  of IntValue:
    result = v.intVal
  of FloatValue:
    result = v.floatVal.int64
  else:
    raise newException(RuntimeError, fmt"Cannot convert {v.kind} to int")

# Type name for error messages
proc typeName*(v: Value): string =
  if v.isNil:
    return "nil"
  case v.kind
  of NilValue: "nil"
  of BoolValue: "bool"
  of IntValue: "int"
  of FloatValue: "float"
  of StringValue: "string"
  of ArrayValue: "array"
  of TableValue: "table"
  of SetValue: "set"
  of ObjectValue: v.objType
  of ProcValue: "proc"
  of NativeProcValue: "native proc"
  of TypeValue: "type"
  of RangeValue: "range"

# Node to string for debugging
proc `$`*(n: Node): string =
  if n.isNil:
    return "<nil>"
  result = $n.kind
  case n.kind
  of IntLitNode:
    result.add fmt"({n.intVal})"
  of FloatLitNode:
    result.add fmt"({n.floatVal})"
  of StrLitNode:
    result.add "(\"" & n.strVal & "\")"
  of BoolLitNode:
    result.add fmt"({n.boolVal})"
  of IdentNode:
    result.add fmt"({n.name})"
  of BinaryOpNode:
    result.add fmt"({n.binOp})"
  of UnaryOpNode:
    result.add fmt"({n.unOp})"
  else:
    discard

# Token to string for debugging
proc `$`*(t: Token): string =
  result = "Token(" & $t.kind & ", \"" & t.lexeme & "\", " & $t.line & ":" & $t.col & ")"

# Check if a value is in a set
proc setContains*(s: Value, elem: Value): bool =
  for v in s.setVal:
    if equals(v, elem):
      return true
  false

# Error formatting
proc formatError*(msg: string, line, col: int, source: string = ""): string =
  result = fmt"Error at line {line}, column {col}: {msg}"
  if source.len > 0:
    let lines = source.splitLines()
    if line > 0 and line <= lines.len:
      result.add "\n" & lines[line - 1]
      result.add "\n" & " ".repeat(col - 1) & "^"
