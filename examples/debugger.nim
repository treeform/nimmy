## Simple step-by-step debugger for Nimmy scripts.
## Press Enter to advance to the next statement.
import
  std/[os, strutils, tables, terminal],
  ../src/nimmy_types,
  ../src/nimmy_parser,
  ../src/nimmy_vm,
  ../src/nimmy_utils
proc clearScreen() =
  eraseScreen()
  setCursorPos(0, 0)
proc formatValue(v: Value, indent = 0): string =
  ## Formats a value with nested structure display.
  let pad = "  ".repeat(indent)
  if v.isNil:
    return pad & "nil"
  case v.kind
  of vkNil: pad & "nil"
  of vkBool: pad & $v.boolVal
  of vkInt: pad & $v.intVal
  of vkFloat: pad & $v.floatVal
  of vkString: pad & "\"" & v.strVal & "\""
  of vkArray:
    if v.arrayVal.len == 0:
      pad & "[]"
    else:
      var lines = @[pad & "["]
      for i, elem in v.arrayVal:
        let comma = if i < v.arrayVal.len - 1: "," else: ""
        lines.add(formatValue(elem, indent + 1) & comma)
      lines.add(pad & "]")
      lines.join("\n")
  of vkTable:
    if v.tableVal.len == 0:
      pad & "{}"
    else:
      var lines = @[pad & "{"]
      var i = 0
      for k, val in v.tableVal:
        let comma = if i < v.tableVal.len - 1: "," else: ""
        lines.add(pad & "  \"" & k & "\": " & formatValue(val, 0).strip() & comma)
        i += 1
      lines.add(pad & "}")
      lines.join("\n")
  of vkObject:
    var lines = @[pad & v.objType & " {"]
    for fieldName, fieldVal in v.objFields:
      lines.add(pad & "  " & fieldName & ": " & formatValue(fieldVal, 0).strip())
    lines.add(pad & "}")
    lines.join("\n")
  of vkProc: pad & "<proc " & v.procName & ">"
  of vkNativeProc: pad & "<native " & v.nativeName & ">"
  of vkType: pad & "<type " & v.typeNameVal & ">"
  of vkRange:
    if v.rangeInclusive: pad & $v.rangeStart & ".." & $v.rangeEnd
    else: pad & $v.rangeStart & "..<" & $v.rangeEnd
proc printLocals(vm: VM) =
  ## Prints all local variables with nested structure.
  echo "--- Local Variables ---"
  var hasVars = false
  var scope = vm.currentScope
  var depth = 0
  while scope != nil:
    for name, value in scope.vars:
      hasVars = true
      let prefix = if depth > 0: "(outer) " else: ""
      echo prefix & name & " = "
      echo formatValue(value, 1)
    scope = scope.parent
    depth += 1
  if not hasVars:
    echo "  (none)"
  echo ""
proc printCurrentState(source: string, lineNum: int, vm: VM) =
  ## Prints the current execution state.
  clearScreen()
  echo "=========================================="
  echo "  NIMMY DEBUGGER - Line " & $lineNum
  echo "=========================================="
  echo ""
  let lines = source.splitLines()
  let startLine = max(1, lineNum - 2)
  let endLine = min(lines.len, lineNum + 2)
  echo "--- Source ---"
  for i in startLine .. endLine:
    let marker = if i == lineNum: " >> " else: "    "
    let lineContent = if i <= lines.len: lines[i - 1] else: ""
    echo marker & $i & " | " & lineContent
  echo ""
  printLocals(vm)
  echo "--- Output ---"
  if vm.output.len > 0:
    for line in vm.output:
      echo "  " & line
  else:
    echo "  (none)"
  echo ""
  echo "[Press Enter to continue, 'q' to quit]"
proc waitForInput(): bool =
  ## Waits for user input, returns false if user wants to quit.
  let input = stdin.readLine()
  input.toLowerAscii() != "q"
proc evalWithDebug(vm: VM, node: Node, source: string): Value =
  ## Evaluates a node with debugging pauses at each statement.
  if node.isNil:
    return nilValue()
  case node.kind
  of nkProgram, nkBlock:
    result = nilValue()
    for stmt in node.stmts:
      if stmt.line > 0:
        printCurrentState(source, stmt.line, vm)
        if not waitForInput():
          echo "Debugger terminated."
          quit(0)
      result = vm.eval(stmt)
  else:
    result = vm.eval(node)
proc runDebugger(scriptPath: string) =
  ## Main debugger entry point.
  if not fileExists(scriptPath):
    echo "Error: File not found: " & scriptPath
    quit(1)
  let source = readFile(scriptPath)
  let ast = parse(source)
  let vm = newVM()
  vm.addProc("len") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "len() takes exactly 1 argument")
    case args[0].kind
    of vkString: intValue(args[0].strVal.len)
    of vkArray: intValue(args[0].arrayVal.len)
    of vkTable: intValue(args[0].tableVal.len)
    else: raise newException(RuntimeError, "Cannot get length of " & typeName(args[0]))
  vm.addProc("str") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "str() takes exactly 1 argument")
    stringValue($args[0])
  vm.addProc("add") do (args: seq[Value]) -> Value:
    if args.len != 2:
      raise newException(RuntimeError, "add() takes exactly 2 arguments")
    if args[0].kind != vkArray:
      raise newException(RuntimeError, "First argument to add() must be an array")
    args[0].arrayVal.add(args[1])
    args[0]
  clearScreen()
  echo "=========================================="
  echo "  NIMMY DEBUGGER"
  echo "=========================================="
  echo ""
  echo "Script: " & scriptPath
  echo ""
  echo "Press Enter to start stepping through the script."
  echo "Press 'q' and Enter to quit at any time."
  echo ""
  discard stdin.readLine()
  try:
    discard evalWithDebug(vm, ast, source)
    printCurrentState(source, 0, vm)
    echo "--- Execution Complete ---"
    echo ""
    echo "Final output:"
    if vm.output.len > 0:
      for line in vm.output:
        echo "  " & line
    else:
      echo "  (none)"
  except NimmyError as e:
    echo ""
    echo "Error: " & e.msg
    quit(1)
when isMainModule:
  if paramCount() < 1:
    echo "Usage: debugger <script.nimmy>"
    echo ""
    echo "A simple step-by-step debugger for Nimmy scripts."
    echo "Press Enter to advance to the next statement."
    quit(0)
  runDebugger(paramStr(1))
