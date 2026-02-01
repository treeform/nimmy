## nimmy_types.nim
## Core type definitions for the Nimmy scripting language

import std/[tables, hashes]

type
  TokenKind* = enum
    # Literals
    tkInt,          # 123
    tkFloat,        # 3.14
    tkString,       # "hello"
    tkTrue,         # true
    tkFalse,        # false
    tkNil,          # nil
    tkIdent,        # variable/function names

    # Keywords
    tkLet,          # let
    tkVar,          # var
    tkProc,         # proc
    tkFunc,         # func (alias for proc)
    tkIf,           # if
    tkElif,         # elif
    tkElse,         # else
    tkFor,          # for
    tkWhile,        # while
    tkBreak,        # break
    tkContinue,     # continue
    tkReturn,       # return
    tkIn,           # in
    tkNot,          # not
    tkAnd,          # and
    tkOr,           # or
    tkType,         # type
    tkObject,       # object
    tkEcho,         # echo (built-in)

    # Operators
    tkPlus,         # +
    tkMinus,        # -
    tkStar,         # *
    tkSlash,        # /
    tkPercent,      # %
    tkAmp,          # &
    tkEq,           # =
    tkEqEq,         # ==
    tkNotEq,        # !=
    tkLt,           # <
    tkLe,           # <=
    tkGt,           # >
    tkGe,           # >=
    tkDotDot,       # ..
    tkDotDotLt,     # ..<
    tkDollar,       # $

    # Delimiters
    tkLParen,       # (
    tkRParen,       # )
    tkLBracket,     # [
    tkRBracket,     # ]
    tkLBrace,       # {
    tkRBrace,       # }
    tkComma,        # ,
    tkDot,          # .
    tkColon,        # :
    tkSemicolon,    # ;

    # Structure
    tkNewline,      # \n (significant)
    tkIndent,       # increase in indentation
    tkDedent,       # decrease in indentation
    tkEof           # end of file

  Token* = object
    kind*: TokenKind
    lexeme*: string
    line*: int
    col*: int

  # AST Node types
  NodeKind* = enum
    nkEmpty,
    nkIntLit,
    nkFloatLit,
    nkStrLit,
    nkBoolLit,
    nkNilLit,
    nkIdent,
    nkBinaryOp,
    nkUnaryOp,
    nkCall,
    nkIndex,
    nkDot,
    nkLetStmt,
    nkVarStmt,
    nkAssign,
    nkIfStmt,
    nkElifBranch,
    nkElseBranch,
    nkForStmt,
    nkWhileStmt,
    nkBreakStmt,
    nkContinueStmt,
    nkReturnStmt,
    nkProcDef,
    nkTypeDef,
    nkObjectDef,
    nkFieldDef,
    nkBlock,
    nkEchoStmt,
    nkProgram,
    nkArray,
    nkTable,
    nkSet,
    nkRange

  Node* = ref object
    line*: int
    col*: int
    case kind*: NodeKind
    of nkIntLit:
      intVal*: int64
    of nkFloatLit:
      floatVal*: float64
    of nkStrLit:
      strVal*: string
    of nkBoolLit:
      boolVal*: bool
    of nkNilLit:
      discard
    of nkIdent:
      name*: string
    of nkBinaryOp:
      binOp*: string
      binLeft*, binRight*: Node
    of nkUnaryOp:
      unOp*: string
      unOperand*: Node
    of nkCall:
      callee*: Node
      args*: seq[Node]
    of nkIndex:
      indexee*: Node
      index*: Node
    of nkDot:
      dotLeft*: Node
      dotField*: string
    of nkLetStmt, nkVarStmt:
      varName*: string
      varValue*: Node
    of nkAssign:
      assignTarget*: Node
      assignValue*: Node
    of nkIfStmt:
      ifCond*: Node
      ifBody*: Node
      elifBranches*: seq[Node]
      elseBranch*: Node
    of nkElifBranch:
      elifCond*: Node
      elifBody*: Node
    of nkElseBranch:
      elseBody*: Node
    of nkForStmt:
      forVar*: string
      forIter*: Node
      forBody*: Node
    of nkWhileStmt:
      whileCond*: Node
      whileBody*: Node
    of nkBreakStmt, nkContinueStmt:
      discard
    of nkReturnStmt:
      returnValue*: Node
    of nkProcDef:
      procName*: string
      procParams*: seq[string]
      procBody*: Node
    of nkTypeDef:
      typeName*: string
      typeBody*: Node
    of nkObjectDef:
      objectFields*: seq[Node]
    of nkFieldDef:
      fieldName*: string
    of nkBlock, nkProgram:
      stmts*: seq[Node]
    of nkEchoStmt:
      echoArgs*: seq[Node]
    of nkArray:
      arrayElems*: seq[Node]
    of nkTable:
      tableKeys*: seq[Node]
      tableVals*: seq[Node]
    of nkSet:
      setElems*: seq[Node]
    of nkRange:
      rangeStart*: Node
      rangeEnd*: Node
      rangeInclusive*: bool
    of nkEmpty:
      discard

  # Runtime value types
  ValueKind* = enum
    vkNil,
    vkBool,
    vkInt,
    vkFloat,
    vkString,
    vkArray,
    vkTable,
    vkSet,
    vkObject,
    vkProc,
    vkNativeProc,
    vkType,
    vkRange

  NativeProc* = proc(args: seq[Value]): Value {.nimcall.}

  Value* = ref object
    case kind*: ValueKind
    of vkNil:
      discard
    of vkBool:
      boolVal*: bool
    of vkInt:
      intVal*: int64
    of vkFloat:
      floatVal*: float64
    of vkString:
      strVal*: string
    of vkArray:
      arrayVal*: seq[Value]
    of vkTable:
      tableVal*: TableRef[string, Value]
    of vkSet:
      setVal*: seq[Value]
    of vkObject:
      objType*: string
      objFields*: TableRef[string, Value]
    of vkProc:
      procName*: string
      procParams*: seq[string]
      procBody*: Node
      procClosure*: Scope
    of vkNativeProc:
      nativeName*: string
      nativeProc*: NativeProc
    of vkType:
      typeNameVal*: string
      typeFields*: seq[string]
    of vkRange:
      rangeStart*: int64
      rangeEnd*: int64
      rangeInclusive*: bool

  # Scope for variable lookup
  Scope* = ref object
    parent*: Scope
    vars*: TableRef[string, Value]
    isConst*: TableRef[string, bool]

  # Error types
  NimmyError* = object of CatchableError
    line*: int
    col*: int

  LexerError* = object of NimmyError
  ParseError* = object of NimmyError
  RuntimeError* = object of NimmyError

  # Debug info
  DebugInfo* = object
    breakpoints*: seq[int]  # line numbers
    stepMode*: bool
    currentLine*: int

# Value constructors
proc nilValue*(): Value =
  Value(kind: vkNil)

proc boolValue*(b: bool): Value =
  Value(kind: vkBool, boolVal: b)

proc intValue*(i: int64): Value =
  Value(kind: vkInt, intVal: i)

proc floatValue*(f: float64): Value =
  Value(kind: vkFloat, floatVal: f)

proc stringValue*(s: string): Value =
  Value(kind: vkString, strVal: s)

proc arrayValue*(arr: seq[Value]): Value =
  Value(kind: vkArray, arrayVal: arr)

proc tableValue*(): Value =
  Value(kind: vkTable, tableVal: newTable[string, Value]())

proc setValue*(elems: seq[Value]): Value =
  Value(kind: vkSet, setVal: elems)

proc objectValue*(typeName: string): Value =
  Value(kind: vkObject, objType: typeName, objFields: newTable[string, Value]())

proc procValue*(name: string, params: seq[string], body: Node, closure: Scope): Value =
  Value(kind: vkProc, procName: name, procParams: params, procBody: body, procClosure: closure)

proc nativeProcValue*(name: string, p: NativeProc): Value =
  Value(kind: vkNativeProc, nativeName: name, nativeProc: p)

proc typeValue*(name: string, fields: seq[string]): Value =
  Value(kind: vkType, typeNameVal: name, typeFields: fields)

proc rangeValue*(start, stop: int64, inclusive: bool): Value =
  Value(kind: vkRange, rangeStart: start, rangeEnd: stop, rangeInclusive: inclusive)

# Scope operations
proc newScope*(parent: Scope = nil): Scope =
  Scope(parent: parent, vars: newTable[string, Value](), isConst: newTable[string, bool]())

proc define*(scope: Scope, name: string, value: Value, isConst: bool = false) =
  scope.vars[name] = value
  scope.isConst[name] = isConst

proc lookup*(scope: Scope, name: string): Value =
  var current = scope
  while current != nil:
    if current.vars.hasKey(name):
      return current.vars[name]
    current = current.parent
  return nil

proc assign*(scope: Scope, name: string, value: Value): bool =
  var current = scope
  while current != nil:
    if current.vars.hasKey(name):
      if current.isConst.getOrDefault(name, false):
        return false  # Cannot assign to const
      current.vars[name] = value
      return true
    current = current.parent
  return false

proc isConstant*(scope: Scope, name: string): bool =
  var current = scope
  while current != nil:
    if current.vars.hasKey(name):
      return current.isConst.getOrDefault(name, false)
    current = current.parent
  return false
