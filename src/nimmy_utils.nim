## nimmy_utils.nim
## Utility functions for the Nimmy scripting language

import nimmy_types
import std/[strformat, strutils, tables]

# Convert Value to string for display
proc `$`*(v: Value): string =
  if v.isNil:
    return "nil"
  case v.kind
  of vkNil:
    result = "nil"
  of vkBool:
    result = $v.boolVal
  of vkInt:
    result = $v.intVal
  of vkFloat:
    result = $v.floatVal
  of vkString:
    result = v.strVal
  of vkArray:
    var parts: seq[string]
    for elem in v.arrayVal:
      parts.add(repr(elem))
    result = "[" & parts.join(", ") & "]"
  of vkTable:
    var parts: seq[string]
    for k, val in v.tableVal:
      parts.add(fmt"{k}: {repr(val)}")
    result = "{" & parts.join(", ") & "}"
  of vkObject:
    var parts: seq[string]
    for k, val in v.objFields:
      parts.add(fmt"{k}: {repr(val)}")
    result = fmt"{v.objType}(" & parts.join(", ") & ")"
  of vkProc:
    result = fmt"<proc {v.procName}>"
  of vkNativeProc:
    result = fmt"<native proc {v.nativeName}>"
  of vkType:
    result = fmt"<type {v.typeNameVal}>"
  of vkRange:
    if v.rangeInclusive:
      result = fmt"{v.rangeStart}..{v.rangeEnd}"
    else:
      result = fmt"{v.rangeStart}..<{v.rangeEnd}"

# Repr for debugging (shows quotes around strings)
proc repr*(v: Value): string =
  if v.isNil:
    return "nil"
  case v.kind
  of vkString:
    result = "\"" & v.strVal & "\""
  else:
    result = $v

# Truthiness check
proc isTruthy*(v: Value): bool =
  if v.isNil:
    return false
  case v.kind
  of vkNil:
    result = false
  of vkBool:
    result = v.boolVal
  of vkInt:
    result = v.intVal != 0
  of vkFloat:
    result = v.floatVal != 0.0
  of vkString:
    result = v.strVal.len > 0
  of vkArray:
    result = v.arrayVal.len > 0
  of vkTable:
    result = v.tableVal.len > 0
  of vkObject:
    result = true
  of vkProc, vkNativeProc, vkType:
    result = true
  of vkRange:
    result = true

# Equality check
proc equals*(a, b: Value): bool =
  if a.isNil and b.isNil:
    return true
  if a.isNil or b.isNil:
    return false
  if a.kind != b.kind:
    # Allow int/float comparison
    if a.kind == vkInt and b.kind == vkFloat:
      return a.intVal.float64 == b.floatVal
    if a.kind == vkFloat and b.kind == vkInt:
      return a.floatVal == b.intVal.float64
    return false
  case a.kind
  of vkNil:
    result = true
  of vkBool:
    result = a.boolVal == b.boolVal
  of vkInt:
    result = a.intVal == b.intVal
  of vkFloat:
    result = a.floatVal == b.floatVal
  of vkString:
    result = a.strVal == b.strVal
  of vkArray:
    if a.arrayVal.len != b.arrayVal.len:
      return false
    for i in 0..<a.arrayVal.len:
      if not equals(a.arrayVal[i], b.arrayVal[i]):
        return false
    result = true
  else:
    # Reference equality for other types
    result = a == b

# Comparison (for < > <= >=)
proc compare*(a, b: Value): int =
  ## Returns -1 if a < b, 0 if a == b, 1 if a > b
  if a.kind == vkInt and b.kind == vkInt:
    return cmp(a.intVal, b.intVal)
  if a.kind == vkFloat and b.kind == vkFloat:
    return cmp(a.floatVal, b.floatVal)
  if a.kind == vkInt and b.kind == vkFloat:
    return cmp(a.intVal.float64, b.floatVal)
  if a.kind == vkFloat and b.kind == vkInt:
    return cmp(a.floatVal, b.intVal.float64)
  if a.kind == vkString and b.kind == vkString:
    return cmp(a.strVal, b.strVal)
  raise newException(RuntimeError, fmt"Cannot compare {a.kind} and {b.kind}")

# Convert Value to float for arithmetic
proc toFloat*(v: Value): float64 =
  case v.kind
  of vkInt:
    result = v.intVal.float64
  of vkFloat:
    result = v.floatVal
  else:
    raise newException(RuntimeError, fmt"Cannot convert {v.kind} to float")

# Convert Value to int
proc toInt*(v: Value): int64 =
  case v.kind
  of vkInt:
    result = v.intVal
  of vkFloat:
    result = v.floatVal.int64
  else:
    raise newException(RuntimeError, fmt"Cannot convert {v.kind} to int")

# Type name for error messages
proc typeName*(v: Value): string =
  if v.isNil:
    return "nil"
  case v.kind
  of vkNil: "nil"
  of vkBool: "bool"
  of vkInt: "int"
  of vkFloat: "float"
  of vkString: "string"
  of vkArray: "array"
  of vkTable: "table"
  of vkObject: v.objType
  of vkProc: "proc"
  of vkNativeProc: "native proc"
  of vkType: "type"
  of vkRange: "range"

# Node to string for debugging
proc `$`*(n: Node): string =
  if n.isNil:
    return "<nil>"
  result = $n.kind
  case n.kind
  of nkIntLit:
    result.add fmt"({n.intVal})"
  of nkFloatLit:
    result.add fmt"({n.floatVal})"
  of nkStrLit:
    result.add "(\"" & n.strVal & "\")"
  of nkBoolLit:
    result.add fmt"({n.boolVal})"
  of nkIdent:
    result.add fmt"({n.name})"
  of nkBinaryOp:
    result.add fmt"({n.binOp})"
  of nkUnaryOp:
    result.add fmt"({n.unOp})"
  else:
    discard

# Token to string for debugging
proc `$`*(t: Token): string =
  result = "Token(" & $t.kind & ", \"" & t.lexeme & "\", " & $t.line & ":" & $t.col & ")"

# Error formatting
proc formatError*(msg: string, line, col: int, source: string = ""): string =
  result = fmt"Error at line {line}, column {col}: {msg}"
  if source.len > 0:
    let lines = source.splitLines()
    if line > 0 and line <= lines.len:
      result.add "\n" & lines[line - 1]
      result.add "\n" & " ".repeat(col - 1) & "^"
