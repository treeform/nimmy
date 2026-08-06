## nimmy_utils.nim
## Utility functions for the Nimmy scripting language

import types
import std/[strformat, strutils, tables, sets]

# Forward declarations
proc typeName*(v: Value): string

const MaxRenderDepth = 512
  ## Cap on nesting depth while rendering a value, so a deeply nested (but
  ## acyclic) structure cannot overflow the host's C stack.

# Render a value to a string. `quoted` puts quotes around strings (debug repr);
# `seen` holds the containers on the current path so cycles are detected instead
# of recursed into forever, and `depth` backstops pathologically deep nesting.
# Every container node charges the instruction budget, so rendering a huge
# structure is bounded like any other work.
proc render(v: Value, seen: var HashSet[pointer], quoted: bool, depth: int): string =
  if v.isNil:
    return "nil"
  case v.kind
  of NilValue:
    return "nil"
  of BoolValue:
    return $v.boolVal
  of IntValue:
    return $v.intVal
  of FloatValue:
    return $v.floatVal
  of StringValue:
    return (if quoted: "\"" & v.strVal & "\"" else: v.strVal)
  of ProcValue:
    return fmt"<proc {v.procName}>"
  of NativeProcValue:
    return fmt"<native proc {v.nativeName}>"
  of TypeValue:
    return fmt"<type {v.typeNameVal}>"
  of RangeValue:
    return (if v.rangeInclusive: fmt"{v.rangeStart}..{v.rangeEnd}"
            else: fmt"{v.rangeStart}..<{v.rangeEnd}")
  of ArgsValue:
    var parts: seq[string]
    for arg in v.argsVal:
      parts.add(render(arg, seen, false, depth))
    return parts.join(" ")
  of ArrayValue, TableValue, SetValue, ObjectValue:
    chargeInstructions(1)
    let identity = cast[pointer](v)
    if depth >= MaxRenderDepth or identity in seen:
      return "..."  # cyclic or too deeply nested
    seen.incl(identity)
    var parts: seq[string]
    case v.kind
    of ArrayValue:
      for elem in v.arrayVal:
        parts.add(render(elem, seen, true, depth + 1))
      result = "[" & parts.join(", ") & "]"
    of TableValue:
      for k, val in v.tableVal:
        parts.add("\"" & k & "\": " & render(val, seen, true, depth + 1))
      result = "{" & parts.join(", ") & "}"
    of SetValue:
      for elem in v.setVal:
        parts.add(render(elem, seen, true, depth + 1))
      result = "{" & parts.join(", ") & "}"
    of ObjectValue:
      for k, val in v.objFields:
        parts.add(fmt"{k}: " & render(val, seen, true, depth + 1))
      result = fmt"{v.objType}(" & parts.join(", ") & ")"
    else:
      discard
    seen.excl(identity)
    return result

# Convert Value to string for display
proc `$`*(v: Value): string =
  var seen = initHashSet[pointer]()
  render(v, seen, false, 0)

# Debug representation (shows quotes around strings)
proc valueRepr*(v: Value): string =
  var seen = initHashSet[pointer]()
  render(v, seen, true, 0)

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
  of ArgsValue:
    result = v.argsVal.len > 0
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
  # One instruction per comparison, so the scans built on equals — contains,
  # `in`, set union/intersection/difference, incl/excl, `==` on nested data —
  # are all bounded by the instruction budget instead of running unaccounted.
  chargeInstructions(1)
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
  of ArgsValue:
    if a.argsVal.len != b.argsVal.len:
      return false
    for i in 0..<a.argsVal.len:
      if not equals(a.argsVal[i], b.argsVal[i]):
        return false
    result = true
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
  of ArgsValue: "args"
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
