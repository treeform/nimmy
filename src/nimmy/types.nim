## nimmy_types.nim
## Core type definitions for the Nimmy scripting language

import std/[tables, hashes]

type
  TokenKind* = enum
    # Literals
    IntToken,          # 123
    FloatToken,        # 3.14
    StringToken,       # "hello"
    TrueToken,         # true
    FalseToken,        # false
    NilToken,          # nil
    IdentToken,        # variable/function names

    # Keywords
    LetToken,          # let
    VarToken,          # var
    ProcToken,         # proc
    FuncToken,         # func (alias for proc)
    IfToken,           # if
    ElifToken,         # elif
    ElseToken,         # else
    ForToken,          # for
    WhileToken,        # while
    BreakToken,        # break
    ContinueToken,     # continue
    ReturnToken,       # return
    InToken,           # in
    NotToken,          # not
    AndToken,          # and
    OrToken,           # or
    TypeToken,         # type
    ObjectToken,       # object
    EchoToken,         # echo (built-in)

    # Operators
    PlusToken,         # +
    MinusToken,        # -
    StarToken,         # *
    SlashToken,        # /
    PercentToken,      # %
    AmpToken,          # &
    EqToken,           # =
    EqEqToken,         # ==
    NotEqToken,        # !=
    LtToken,           # <
    LeToken,           # <=
    GtToken,           # >
    GeToken,           # >=
    DotDotToken,       # ..
    DotDotLtToken,     # ..<
    DollarToken,       # $

    # Delimiters
    LParenToken,       # (
    RParenToken,       # )
    LBracketToken,     # [
    RBracketToken,     # ]
    LBraceToken,       # {
    RBraceToken,       # }
    CommaToken,        # ,
    DotToken,          # .
    ColonToken,        # :
    SemicolonToken,    # ;

    # Structure
    NewlineToken,      # \n (significant)
    IndentToken,       # increase in indentation
    DedentToken,       # decrease in indentation
    EofToken           # end of file

  Token* = object
    kind*: TokenKind
    lexeme*: string
    line*: int
    col*: int

  # AST Node types
  NodeKind* = enum
    EmptyNode,
    IntLitNode,
    FloatLitNode,
    StrLitNode,
    BoolLitNode,
    NilLitNode,
    IdentNode,
    BinaryOpNode,
    UnaryOpNode,
    CallNode,
    IndexNode,
    DotNode,
    LetStmtNode,
    VarStmtNode,
    AssignNode,
    IfStmtNode,
    ElifBranchNode,
    ElseBranchNode,
    ForStmtNode,
    WhileStmtNode,
    BreakStmtNode,
    ContinueStmtNode,
    ReturnStmtNode,
    ProcDefNode,
    TypeDefNode,
    ObjectDefNode,
    FieldDefNode,
    BlockNode,
    EchoStmtNode,
    ProgramNode,
    ArrayNode,
    TableNode,
    SetNode,
    RangeNode

  Node* = ref object
    line*: int
    col*: int
    case kind*: NodeKind
    of IntLitNode:
      intVal*: int64
    of FloatLitNode:
      floatVal*: float64
    of StrLitNode:
      strVal*: string
    of BoolLitNode:
      boolVal*: bool
    of NilLitNode:
      discard
    of IdentNode:
      name*: string
    of BinaryOpNode:
      binOp*: string
      binLeft*, binRight*: Node
    of UnaryOpNode:
      unOp*: string
      unOperand*: Node
    of CallNode:
      callee*: Node
      args*: seq[Node]
    of IndexNode:
      indexee*: Node
      index*: Node
    of DotNode:
      dotLeft*: Node
      dotField*: string
    of LetStmtNode, VarStmtNode:
      varName*: string
      varValue*: Node
    of AssignNode:
      assignTarget*: Node
      assignValue*: Node
    of IfStmtNode:
      ifCond*: Node
      ifBody*: Node
      elifBranches*: seq[Node]
      elseBranch*: Node
    of ElifBranchNode:
      elifCond*: Node
      elifBody*: Node
    of ElseBranchNode:
      elseBody*: Node
    of ForStmtNode:
      forVar*: string
      forIter*: Node
      forBody*: Node
    of WhileStmtNode:
      whileCond*: Node
      whileBody*: Node
    of BreakStmtNode, ContinueStmtNode:
      discard
    of ReturnStmtNode:
      returnValue*: Node
    of ProcDefNode:
      procName*: string
      procParams*: seq[string]
      procBody*: Node
    of TypeDefNode:
      typeName*: string
      typeBody*: Node
    of ObjectDefNode:
      objectFields*: seq[Node]
    of FieldDefNode:
      fieldName*: string
    of BlockNode, ProgramNode:
      stmts*: seq[Node]
    of EchoStmtNode:
      echoArgs*: seq[Node]
    of ArrayNode:
      arrayElems*: seq[Node]
    of TableNode:
      tableKeys*: seq[Node]
      tableVals*: seq[Node]
    of SetNode:
      setElems*: seq[Node]
    of RangeNode:
      rangeStart*: Node
      rangeEnd*: Node
      rangeInclusive*: bool
    of EmptyNode:
      discard

  # Runtime value types
  ValueKind* = enum
    NilValue,
    BoolValue,
    IntValue,
    FloatValue,
    StringValue,
    ArrayValue,
    TableValue,
    SetValue,
    ObjectValue,
    ProcValue,
    NativeProcValue,
    TypeValue,
    RangeValue

  NativeProc* = proc(args: seq[Value]): Value {.nimcall.}

  Value* = ref object
    case kind*: ValueKind
    of NilValue:
      discard
    of BoolValue:
      boolVal*: bool
    of IntValue:
      intVal*: int64
    of FloatValue:
      floatVal*: float64
    of StringValue:
      strVal*: string
    of ArrayValue:
      arrayVal*: seq[Value]
    of TableValue:
      tableVal*: TableRef[string, Value]
    of SetValue:
      setVal*: seq[Value]
    of ObjectValue:
      objType*: string
      objFields*: TableRef[string, Value]
    of ProcValue:
      procName*: string
      procParams*: seq[string]
      procBody*: Node
      procClosure*: Scope
    of NativeProcValue:
      nativeName*: string
      nativeProc*: NativeProc
    of TypeValue:
      typeNameVal*: string
      typeFields*: seq[string]
    of RangeValue:
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
  Value(kind: NilValue)

proc boolValue*(b: bool): Value =
  Value(kind: BoolValue, boolVal: b)

proc intValue*(i: int64): Value =
  Value(kind: IntValue, intVal: i)

proc floatValue*(f: float64): Value =
  Value(kind: FloatValue, floatVal: f)

proc stringValue*(s: string): Value =
  Value(kind: StringValue, strVal: s)

proc arrayValue*(arr: seq[Value]): Value =
  Value(kind: ArrayValue, arrayVal: arr)

proc tableValue*(): Value =
  Value(kind: TableValue, tableVal: newTable[string, Value]())

proc setValue*(elems: seq[Value]): Value =
  Value(kind: SetValue, setVal: elems)

proc objectValue*(typeName: string): Value =
  Value(kind: ObjectValue, objType: typeName, objFields: newTable[string, Value]())

proc procValue*(name: string, params: seq[string], body: Node, closure: Scope): Value =
  Value(kind: ProcValue, procName: name, procParams: params, procBody: body, procClosure: closure)

proc nativeProcValue*(name: string, p: NativeProc): Value =
  Value(kind: NativeProcValue, nativeName: name, nativeProc: p)

proc typeValue*(name: string, fields: seq[string]): Value =
  Value(kind: TypeValue, typeNameVal: name, typeFields: fields)

proc rangeValue*(start, stop: int64, inclusive: bool): Value =
  Value(kind: RangeValue, rangeStart: start, rangeEnd: stop, rangeInclusive: inclusive)

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
