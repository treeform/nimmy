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

  # Runtime value types
  ValueKind* = enum
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
    of ArgsValue:
      argsVal*: seq[Value]
    of ArrayValue:
      arrayVal*: seq[Value]
    of TableValue:
      tableVal*: OrderedTableRef[string, Value]
    of SetValue:
      setVal*: seq[Value]
    of ObjectValue:
      objType*: string
      objFields*: OrderedTableRef[string, Value]
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
    vars*: OrderedTableRef[string, Value]
    isConst*: OrderedTableRef[string, bool]
    sealed*: OrderedTableRef[string, bool]  ## Names a script may not redefine or assign

  # Error types. Everything a script can trigger surfaces as a NimmyError so a
  # host can catch one type and keep running.
  NimmyError* = object of CatchableError
    line*: int
    col*: int

  LexerError* = object of NimmyError
  ParseError* = object of NimmyError
  RuntimeError* = object of NimmyError
  LimitError* = object of RuntimeError
    ## A resource budget was exhausted: instruction budget, per-step
    ## instruction cap, allocation budget or call depth.

  ## Resource accounting for one VM. Every counter lives here, owned by the VM
  ## that runs the script, so two VMs never share or clobber each other's
  ## budgets and the host can inspect usage per script. A limit of 0 means
  ## unlimited.
  Budget* = ref object
    instructions*: int          ## Instructions charged this run
    instructionLimit*: int      ## Cap on instructions per run (maxSteps)
    stepInstructions*: int      ## Instructions charged since the current step began
    stepInstructionLimit*: int  ## Cap on instructions a single step may charge
    allocations*: int           ## Allocation units charged this run
    allocationLimit*: int       ## Cap on allocation units per run

  # Debug info
  DebugInfo* = object
    breakpoints*: seq[int]  # line numbers
    stepMode*: bool
    currentLine*: int

## Budget accounting
##
## Allocations are a deterministic budget on the heap-backed data a script
## creates (approximate bytes), catching super-linear growth (e.g. `s = s & s`
## in a loop) that an instruction count cannot. Units are deterministic across
## platforms (unlike getOccupiedMem), preserving Nimmy's lockstep guarantee.
## The VM charges at every site that creates script-visible data; hosts that
## build large values in their own natives can charge through `vm.budget`.

proc newBudget*(instructionLimit, allocationLimit: int,
                stepInstructionLimit = 0): Budget =
  Budget(instructionLimit: instructionLimit, allocationLimit: allocationLimit,
         stepInstructionLimit: stepInstructionLimit)

proc reset*(budget: Budget) =
  ## Begin a fresh run: counters to zero, limits unchanged.
  budget.instructions = 0
  budget.stepInstructions = 0
  budget.allocations = 0

proc beginStep*(budget: Budget) =
  ## Called by the VM at the start of every step().
  budget.stepInstructions = 0

proc chargeInstructions*(budget: Budget, n: int) =
  ## Account for `n` instructions against the run budget and the per-step cap.
  ## Raises a catchable LimitError when either is exhausted.
  if budget.isNil or n <= 0:
    return
  budget.instructions += n
  budget.stepInstructions += n
  if budget.instructionLimit > 0 and budget.instructions > budget.instructionLimit:
    raise newException(LimitError, "Maximum step count exceeded")
  if budget.stepInstructionLimit > 0 and
      budget.stepInstructions > budget.stepInstructionLimit:
    raise newException(LimitError, "Maximum instructions per step exceeded")

proc chargeAllocation*(budget: Budget, units: int) =
  ## Account for `units` of allocation. Raises a catchable LimitError when the
  ## budget is exhausted.
  if budget.isNil or units <= 0:
    return
  budget.allocations += units
  if budget.allocationLimit > 0 and budget.allocations > budget.allocationLimit:
    raise newException(LimitError, "Maximum allocation exceeded")

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

proc argsValue*(args: seq[Value]): Value =
  Value(kind: ArgsValue, argsVal: args)

proc arrayValue*(arr: seq[Value]): Value =
  Value(kind: ArrayValue, arrayVal: arr)

proc tableValue*(): Value =
  Value(kind: TableValue, tableVal: newOrderedTable[string, Value]())

proc setValue*(elems: seq[Value]): Value =
  Value(kind: SetValue, setVal: elems)

proc objectValue*(typeName: string): Value =
  Value(kind: ObjectValue, objType: typeName, objFields: newOrderedTable[string, Value]())

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
