## nimmy_debug.nim
## Debugger support for the Nimmy scripting language

import nimmy_types
import nimmy_utils
import nimmy_vm
import std/[strformat, tables, strutils]

type
  Debugger* = ref object
    vm*: VM
    breakpoints*: seq[int]
    stepMode*: bool
    paused*: bool
    callStack*: seq[string]

proc newDebugger*(vm: VM): Debugger =
  Debugger(
    vm: vm,
    breakpoints: @[],
    stepMode: false,
    paused: false,
    callStack: @["<main>"]
  )

proc addBreakpoint*(d: Debugger, line: int) =
  if line notin d.breakpoints:
    d.breakpoints.add(line)

proc removeBreakpoint*(d: Debugger, line: int) =
  let idx = d.breakpoints.find(line)
  if idx >= 0:
    d.breakpoints.delete(idx)

proc clearBreakpoints*(d: Debugger) =
  d.breakpoints = @[]

proc hasBreakpoint*(d: Debugger, line: int): bool =
  line in d.breakpoints

proc enableStepMode*(d: Debugger) =
  d.stepMode = true

proc disableStepMode*(d: Debugger) =
  d.stepMode = false

proc pause*(d: Debugger) =
  d.paused = true

proc resume*(d: Debugger) =
  d.paused = false

proc pushCall*(d: Debugger, name: string) =
  d.callStack.add(name)

proc popCall*(d: Debugger) =
  if d.callStack.len > 1:
    discard d.callStack.pop()

# Get all variables in the current scope
proc getLocals*(d: Debugger): seq[(string, Value)] =
  result = @[]
  var scope = d.vm.currentScope
  while scope != nil:
    for name, value in scope.vars:
      result.add((name, value))
    scope = scope.parent

# Get variables only in the innermost scope
proc getCurrentLocals*(d: Debugger): seq[(string, Value)] =
  result = @[]
  for name, value in d.vm.currentScope.vars:
    result.add((name, value))

# Get the call stack
proc getStackTrace*(d: Debugger): seq[string] =
  result = d.callStack

# Format locals for display
proc formatLocals*(d: Debugger): string =
  var lines: seq[string] = @[]
  lines.add("Local variables:")
  for (name, value) in d.getCurrentLocals():
    lines.add(fmt"  {name} = {repr(value)}")
  if lines.len == 1:
    lines.add("  (none)")
  result = lines.join("\n")

# Format all variables for display
proc formatAllVars*(d: Debugger): string =
  var lines: seq[string] = @[]
  lines.add("All variables:")
  for (name, value) in d.getLocals():
    lines.add(fmt"  {name} = {repr(value)}")
  if lines.len == 1:
    lines.add("  (none)")
  result = lines.join("\n")

# Format stack trace for display
proc formatStackTrace*(d: Debugger): string =
  var lines: seq[string] = @[]
  lines.add("Stack trace:")
  for i, name in d.callStack:
    let indent = "  ".repeat(i)
    lines.add(fmt"{indent}{name}")
  result = lines.join("\n")

# Inspect a specific variable
proc inspect*(d: Debugger, name: string): string =
  let value = d.vm.currentScope.lookup(name)
  if value.isNil:
    return fmt"Variable '{name}' not found"
  
  case value.kind
  of vkObject:
    var lines: seq[string] = @[]
    lines.add(fmt"{name}: {value.objType}")
    for fieldName, fieldVal in value.objFields:
      lines.add(fmt"  .{fieldName} = {repr(fieldVal)}")
    return lines.join("\n")
  of vkArray:
    var lines: seq[string] = @[]
    lines.add(fmt"{name}: array[{value.arrayVal.len}]")
    for i, elem in value.arrayVal:
      lines.add(fmt"  [{i}] = {repr(elem)}")
    return lines.join("\n")
  of vkTable:
    var lines: seq[string] = @[]
    lines.add(fmt"{name}: table[{value.tableVal.len}]")
    for key, val in value.tableVal:
      lines.add("  [\"" & key & "\"] = " & repr(val))
    return lines.join("\n")
  else:
    return fmt"{name} = {repr(value)}"

# Debug state summary
proc status*(d: Debugger): string =
  var lines: seq[string] = @[]
  lines.add(fmt"Paused: {d.paused}")
  lines.add(fmt"Step mode: {d.stepMode}")
  lines.add(fmt"Breakpoints: {d.breakpoints}")
  lines.add(fmt"Call depth: {d.callStack.len}")
  result = lines.join("\n")
