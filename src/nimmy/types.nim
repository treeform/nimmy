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
    DivToken,          # div
    TypeToken,         # type
    ObjectToken,       # object

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

  # Runtime value types. MissingValue is first so a default Value()
  # means "absent", used by lookups to signal a name that does not
  # exist. It is never visible to scripts, which only ever see
  # NilValue and later kinds.
  ValueKind* = enum
    MissingValue,
    NilValue,
    BoolValue,
    IntValue,
    FloatValue,
    StringValue,
    ArgsValue,
    ArrayValue,
    TableValue,
    SetValue,
    ObjectValue,
    ProcValue,
    NativeProcValue,
    TypeValue,
    RangeValue

  NativeProc* = proc(args: seq[Value]): Value {.closure.}

  ## Heap payloads. Everything that is not a plain scalar sits behind
  ## exactly one ref, so copying a Value is a small memcpy plus at
  ## most one reference count, and copies share the payload, which
  ## preserves the reference semantics scripts expect.
  ObjPayload* = object
    typeName*: string
    fields*: OrderedTableRef[string, Value]

  ProcPayload* = object
    name*: string
    params*: seq[string]
    body*: Node
    closure*: Scope

  NativePayload* = object
    name*: string
    call*: NativeProc

  TypePayload* = object
    name*: string
    fields*: seq[string]

  ## Values are small by-value variant objects, so ints, bools and
  ## floats never touch the heap at all.
  Value* = object
    case kind*: ValueKind
    of MissingValue, NilValue:
      discard
    of BoolValue:
      boolVal*: bool
    of IntValue:
      intVal*: int64
    of FloatValue:
      floatVal*: float64
    of StringValue:
      strRef*: ref string
    of ArgsValue:
      argsRef*: ref seq[Value]
    of ArrayValue:
      arrayRef*: ref seq[Value]
    of TableValue:
      tableVal*: OrderedTableRef[string, Value]
    of SetValue:
      setRef*: ref seq[Value]
    of ObjectValue:
      objRef*: ref ObjPayload
    of ProcValue:
      procRef*: ref ProcPayload
    of NativeProcValue:
      nativeRef*: ref NativePayload
    of TypeValue:
      typeRef*: ref TypePayload
    of RangeValue:
      rangeStart*: int64
      rangeEnd*: int64
      rangeInclusive*: bool

  # Scope for variable lookup
  Scope* = ref object
    parent*: Scope
    vars*: OrderedTableRef[string, Value]
    isConst*: OrderedTableRef[string, bool]
    sealed*: OrderedTableRef[string, bool]  ## Names a script may not redefine or assign

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

# Allocation accounting
#
# A deterministic budget on the heap-backed data a script creates. It bounds
# memory the way maxSteps bounds execution, and catches super-linear growth
# (e.g. `s = s & s` in a loop) that a statement count cannot. Counting happens
# in the value constructors below, so no allocation site can be missed. Units
# are approximate bytes and are deterministic across platforms (unlike
# getOccupiedMem), preserving Nimmy's lockstep guarantee.
var
  allocatedUnits* {.threadvar.}: int   ## Cumulative units charged this run.
  allocationLimit* {.threadvar.}: int  ## Cap in units, 0 means unlimited.

proc chargeAllocation*(units: int) =
  ## Account for `units` of allocation and enforce the limit. Raises a
  ## catchable RuntimeError when the budget is exhausted.
  if units <= 0:
    return
  allocatedUnits += units
  if allocationLimit > 0 and allocatedUnits > allocationLimit:
    raise newException(RuntimeError, "Maximum allocation exceeded")

proc allocationsUsed*(): int =
  ## Units charged since the current run began.
  allocatedUnits

proc resetAllocations*(limit: int) =
  ## Begin a fresh allocation budget for a run.
  allocatedUnits = 0
  allocationLimit = limit

# Instruction accounting
#
# The statement/step budget, exposed thread-locally so that work done outside
# the statement stepper — native builtins and value rendering ($ / echo) — can
# charge against it too. A statement that calls a builtin doing O(n) work, or
# renders a large structure, is bounded instead of running unaccounted.
var
  instructionCount* {.threadvar.}: int  ## Cumulative instructions this run.
  instructionLimit* {.threadvar.}: int  ## Cap, 0 means unlimited.

proc chargeInstructions*(n: int) =
  ## Account for `n` instructions and enforce the limit. Raises a catchable
  ## RuntimeError when the budget is exhausted.
  if n <= 0:
    return
  instructionCount += n
  if instructionLimit > 0 and instructionCount > instructionLimit:
    raise newException(RuntimeError, "Maximum step count exceeded")

proc instructionsUsed*(): int =
  ## Instructions charged since the current run began.
  instructionCount

proc resetInstructions*(limit: int) =
  ## Begin a fresh instruction budget for a run.
  instructionCount = 0
  instructionLimit = limit

## Accessor templates keep the old field syntax working while the
## payloads live behind refs. Derefs are lvalues, so mutation through
## any copy of the Value reaches the shared payload.
template arrayVal*(v: Value): seq[Value] = v.arrayRef[]
template setVal*(v: Value): seq[Value] = v.setRef[]
template strVal*(v: Value): string = v.strRef[]
template argsVal*(v: Value): seq[Value] = v.argsRef[]
template objType*(v: Value): string = v.objRef[].typeName
template objFields*(v: Value): OrderedTableRef[string, Value] =
  v.objRef[].fields
template procName*(v: Value): string = v.procRef[].name
template procParams*(v: Value): seq[string] = v.procRef[].params
template procBody*(v: Value): Node = v.procRef[].body
template procClosure*(v: Value): Scope = v.procRef[].closure
template nativeName*(v: Value): string = v.nativeRef[].name
template nativeProc*(v: Value): NativeProc = v.nativeRef[].call
template typeNameVal*(v: Value): string = v.typeRef[].name
template typeFields*(v: Value): seq[string] = v.typeRef[].fields

proc isMissing*(v: Value): bool {.inline.} =
  ## True for the internal absent marker, never for script nil.
  v.kind == MissingValue

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
  chargeAllocation(s.len + 1)
  result = Value(kind: StringValue)
  new(result.strRef)
  result.strRef[] = s

proc argsValue*(args: seq[Value]): Value =
  result = Value(kind: ArgsValue)
  new(result.argsRef)
  result.argsRef[] = args

proc arrayValue*(arr: seq[Value]): Value =
  chargeAllocation(arr.len * 8 + 8)
  result = Value(kind: ArrayValue)
  new(result.arrayRef)
  result.arrayRef[] = arr

proc tableValue*(): Value =
  chargeAllocation(8)
  Value(kind: TableValue, tableVal: newOrderedTable[string, Value]())

proc setValue*(elems: seq[Value]): Value =
  chargeAllocation(elems.len * 8 + 8)
  result = Value(kind: SetValue)
  new(result.setRef)
  result.setRef[] = elems

proc objectValue*(typeName: string): Value =
  chargeAllocation(8)
  result = Value(kind: ObjectValue)
  new(result.objRef)
  result.objRef[] = ObjPayload(
    typeName: typeName,
    fields: newOrderedTable[string, Value]()
  )

proc procValue*(name: string, params: seq[string], body: Node, closure: Scope): Value =
  result = Value(kind: ProcValue)
  new(result.procRef)
  result.procRef[] = ProcPayload(
    name: name,
    params: params,
    body: body,
    closure: closure
  )

proc nativeProcValue*(name: string, p: NativeProc): Value =
  result = Value(kind: NativeProcValue)
  new(result.nativeRef)
  result.nativeRef[] = NativePayload(name: name, call: p)

proc typeValue*(name: string, fields: seq[string]): Value =
  result = Value(kind: TypeValue)
  new(result.typeRef)
  result.typeRef[] = TypePayload(name: name, fields: fields)

proc rangeValue*(start, stop: int64, inclusive: bool): Value =
  Value(kind: RangeValue, rangeStart: start, rangeEnd: stop, rangeInclusive: inclusive)

# Scope operations
proc newScope*(parent: Scope = nil): Scope =
  Scope(parent: parent, vars: newOrderedTable[string, Value](),
        isConst: newOrderedTable[string, bool](),
        sealed: newOrderedTable[string, bool]())

proc define*(scope: Scope, name: string, value: Value,
             isConst: bool = false, sealed: bool = false) =
  scope.vars[name] = value
  scope.isConst[name] = isConst
  if sealed:
    scope.sealed[name] = true

proc isSealedHere*(scope: Scope, name: string): bool =
  ## Whether `name` is sealed in this exact scope (not a parent).
  scope.sealed.getOrDefault(name, false)

proc isSealed*(scope: Scope, name: string): bool =
  ## Whether the binding `name` resolves to is sealed. A shadowing binding in an
  ## inner scope is not sealed, so scripts can still use the name locally.
  var current = scope
  while current != nil:
    if current.vars.hasKey(name):
      return current.sealed.getOrDefault(name, false)
    current = current.parent
  false

proc lookup*(scope: Scope, name: string): Value =
  ## Returns the missing marker (check with isMissing) when the name
  ## does not exist anywhere in the scope chain.
  var current = scope
  while current != nil:
    if current.vars.hasKey(name):
      return current.vars[name]
    current = current.parent
  return Value(kind: MissingValue)

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
