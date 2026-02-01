## nimmy.nim
## Main entry point and API for the Nimmy scripting language

import nimmy_types
import nimmy_lexer
import nimmy_parser
import nimmy_vm
import nimmy_debug
import nimmy_utils
import std/[strformat, tables, strutils]

export nimmy_types
export nimmy_vm.newVM, nimmy_vm.addProc, nimmy_vm.getOutput, nimmy_vm.clearOutput
export nimmy_debug

type
  NimmyVM* = ref object
    vm*: VM
    debugger*: Debugger

proc newNimmyVM*(): NimmyVM =
  let vm = newVM()
  result = NimmyVM(
    vm: vm,
    debugger: newDebugger(vm)
  )
  
  # Add standard library functions
  
  # len(x) - get length of string, array, or table
  vm.addProc("len") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "len() takes exactly 1 argument")
    let arg = args[0]
    case arg.kind
    of vkString:
      return intValue(arg.strVal.len)
    of vkArray:
      return intValue(arg.arrayVal.len)
    of vkTable:
      return intValue(arg.tableVal.len)
    else:
      raise newException(RuntimeError, fmt"Cannot get length of {typeName(arg)}")
  
  # str(x) - convert to string
  vm.addProc("str") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "str() takes exactly 1 argument")
    return stringValue($args[0])
  
  # int(x) - convert to integer
  vm.addProc("int") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "int() takes exactly 1 argument")
    case args[0].kind
    of vkInt:
      return args[0]
    of vkFloat:
      return intValue(args[0].floatVal.int64)
    of vkString:
      try:
        return intValue(parseInt(args[0].strVal))
      except:
        raise newException(RuntimeError, fmt"Cannot convert '{args[0].strVal}' to int")
    of vkBool:
      return intValue(if args[0].boolVal: 1 else: 0)
    else:
      raise newException(RuntimeError, fmt"Cannot convert {typeName(args[0])} to int")
  
  # float(x) - convert to float
  vm.addProc("float") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "float() takes exactly 1 argument")
    case args[0].kind
    of vkInt:
      return floatValue(args[0].intVal.float64)
    of vkFloat:
      return args[0]
    of vkString:
      try:
        return floatValue(parseFloat(args[0].strVal))
      except:
        raise newException(RuntimeError, fmt"Cannot convert '{args[0].strVal}' to float")
    else:
      raise newException(RuntimeError, fmt"Cannot convert {typeName(args[0])} to float")
  
  # typeof(x) - get type name
  vm.addProc("typeof") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "typeof() takes exactly 1 argument")
    return stringValue(typeName(args[0]))
  
  # push(arr, value) - add to array
  vm.addProc("push") do (args: seq[Value]) -> Value:
    if args.len != 2:
      raise newException(RuntimeError, "push() takes exactly 2 arguments")
    if args[0].kind != vkArray:
      raise newException(RuntimeError, "First argument to push() must be an array")
    args[0].arrayVal.add(args[1])
    return args[0]
  
  # pop(arr) - remove and return last element
  vm.addProc("pop") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "pop() takes exactly 1 argument")
    if args[0].kind != vkArray:
      raise newException(RuntimeError, "Argument to pop() must be an array")
    if args[0].arrayVal.len == 0:
      raise newException(RuntimeError, "Cannot pop from empty array")
    return args[0].arrayVal.pop()
  
  # keys(table) - get keys of table
  vm.addProc("keys") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "keys() takes exactly 1 argument")
    if args[0].kind != vkTable:
      raise newException(RuntimeError, "Argument to keys() must be a table")
    var keys: seq[Value] = @[]
    for k in args[0].tableVal.keys:
      keys.add(stringValue(k))
    return arrayValue(keys)
  
  # values(table) - get values of table
  vm.addProc("values") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "values() takes exactly 1 argument")
    if args[0].kind != vkTable:
      raise newException(RuntimeError, "Argument to values() must be a table")
    var vals: seq[Value] = @[]
    for v in args[0].tableVal.values:
      vals.add(v)
    return arrayValue(vals)
  
  # hasKey(table, key) - check if key exists
  vm.addProc("hasKey") do (args: seq[Value]) -> Value:
    if args.len != 2:
      raise newException(RuntimeError, "hasKey() takes exactly 2 arguments")
    if args[0].kind != vkTable:
      raise newException(RuntimeError, "First argument to hasKey() must be a table")
    if args[1].kind != vkString:
      raise newException(RuntimeError, "Second argument to hasKey() must be a string")
    return boolValue(args[0].tableVal.hasKey(args[1].strVal))
  
  # abs(x) - absolute value
  vm.addProc("abs") do (args: seq[Value]) -> Value:
    if args.len != 1:
      raise newException(RuntimeError, "abs() takes exactly 1 argument")
    case args[0].kind
    of vkInt:
      return intValue(abs(args[0].intVal))
    of vkFloat:
      return floatValue(abs(args[0].floatVal))
    else:
      raise newException(RuntimeError, fmt"Cannot get absolute value of {typeName(args[0])}")
  
  # min(a, b) - minimum value
  vm.addProc("min") do (args: seq[Value]) -> Value:
    if args.len != 2:
      raise newException(RuntimeError, "min() takes exactly 2 arguments")
    if compare(args[0], args[1]) <= 0:
      return args[0]
    return args[1]
  
  # max(a, b) - maximum value
  vm.addProc("max") do (args: seq[Value]) -> Value:
    if args.len != 2:
      raise newException(RuntimeError, "max() takes exactly 2 arguments")
    if compare(args[0], args[1]) >= 0:
      return args[0]
    return args[1]

# Run a script and return the output
proc run*(nvm: NimmyVM, source: string): string =
  let ast = parse(source)
  discard nvm.vm.eval(ast)
  result = nvm.vm.getOutput()
  nvm.vm.clearOutput()

# Run a script from a file
proc runFile*(nvm: NimmyVM, path: string): string =
  let source = readFile(path)
  result = nvm.run(source)

# Add a custom procedure
proc addProc*(nvm: NimmyVM, name: string, p: NativeProc) =
  nvm.vm.addProc(name, p)

# Set a global variable
proc setGlobal*(nvm: NimmyVM, name: string, value: Value) =
  nvm.vm.globalScope.define(name, value)

# Get a global variable
proc getGlobal*(nvm: NimmyVM, name: string): Value =
  nvm.vm.globalScope.lookup(name)

# Debugger access
proc debugger*(nvm: NimmyVM): Debugger =
  nvm.debugger

# Convenience for creating values from Nim types
proc toValue*(s: string): Value = stringValue(s)
proc toValue*(i: int): Value = intValue(i.int64)
proc toValue*(i: int64): Value = intValue(i)
proc toValue*(f: float): Value = floatValue(f)
proc toValue*(b: bool): Value = boolValue(b)

# Main entry point for command-line usage
when isMainModule:
  import std/[os, parseopt]
  
  proc printUsage() =
    echo "Nimmy - A small scripting language"
    echo ""
    echo "Usage:"
    echo "  nimmy <script.nimmy>  - Run a script file"
    echo "  nimmy -e <code>       - Execute code directly"
    echo "  nimmy --help          - Show this help"
    echo ""
  
  var
    scriptFile = ""
    codeToRun = ""
  
  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        printUsage()
        quit(0)
      of "e":
        codeToRun = p.val
      else:
        echo fmt"Unknown option: {p.key}"
        quit(1)
    of cmdArgument:
      scriptFile = p.key
  
  if codeToRun.len > 0:
    let nvm = newNimmyVM()
    let output = nvm.run(codeToRun)
    if output.len > 0:
      echo output
  elif scriptFile.len > 0:
    if not fileExists(scriptFile):
      echo fmt"Error: File not found: {scriptFile}"
      quit(1)
    let nvm = newNimmyVM()
    let output = nvm.runFile(scriptFile)
    if output.len > 0:
      echo output
  else:
    printUsage()
