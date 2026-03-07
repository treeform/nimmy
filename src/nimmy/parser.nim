## nimmy_parser.nim
## Parser/AST builder for the Nimmy scripting language

import types, lexer
import std/[strformat, strutils]

type
  Parser* = ref object
    lexer: Lexer
    current: Token
    upcoming: Token
    previous: Token

proc newParser*(source: string): Parser =
  let lexer = newLexer(source)
  let current = lexer.nextToken()
  let upcoming = lexer.nextToken()
  Parser(lexer: lexer, current: current, upcoming: upcoming)

proc error(P: Parser, msg: string) =
  var e = newException(ParseError, fmt"{msg} at line {P.current.line}, column {P.current.col}")
  e.line = P.current.line
  e.col = P.current.col
  raise e

proc advance(P: Parser): Token =
  P.previous = P.current
  P.current = P.upcoming
  P.upcoming = P.lexer.nextToken()
  result = P.previous

proc check(P: Parser, kind: TokenKind): bool =
  P.current.kind == kind

proc checkAny(P: Parser, kinds: set[TokenKind]): bool =
  P.current.kind in kinds

proc match(P: Parser, kind: TokenKind): bool =
  if P.check(kind):
    discard P.advance()
    return true
  return false

proc consume(P: Parser, kind: TokenKind, msg: string): Token =
  if P.check(kind):
    return P.advance()
  P.error(msg)

proc skipNewlines(P: Parser) =
  while P.check(NewlineToken):
    discard P.advance()

proc skipTableLayout(P: Parser) =
  while P.checkAny({NewlineToken, IndentToken, DedentToken}):
    discard P.advance()

proc hasCommandGap(P: Parser): bool =
  if P.previous.line != P.current.line:
    return false
  if P.previous.lexeme.len == 0:
    return false
  let previousEndCol = P.previous.col + P.previous.lexeme.len
  P.current.col > previousEndCol

proc isAttachedToUpcoming(P: Parser): bool =
  if P.current.line != P.upcoming.line:
    return false
  if P.current.lexeme.len == 0:
    return false
  let currentEndCol = P.current.col + P.current.lexeme.len
  P.upcoming.col == currentEndCol

# Forward declarations
proc expression(P: Parser): Node
proc commandExpr(P: Parser): Node
proc statement(P: Parser): Node
proc parseBlock(P: Parser): Node
proc indentedTable(P: Parser, line, col: int): Node
proc valueExpression(P: Parser): Node

proc configKey(P: Parser): Node =
  let line = P.current.line
  let col = P.current.col

  if P.match(IdentToken):
    return Node(
      kind: StrLitNode,
      line: line,
      col: col,
      strVal: P.previous.lexeme
    )

  if P.match(StringToken):
    return Node(
      kind: StrLitNode,
      line: line,
      col: col,
      strVal: P.previous.lexeme
    )

  P.error("Expected config key")

proc indentedTable(P: Parser, line, col: int): Node =
  var
    keys: seq[Node] = @[]
    vals: seq[Node] = @[]

  discard P.consume(IndentToken, "Expected indented table")
  P.skipNewlines()

  while not P.check(DedentToken) and not P.check(EofToken):
    let key = P.configKey()
    discard P.consume(ColonToken, "Expected ':' after config key")

    var value: Node = nil
    if P.match(NewlineToken):
      if P.check(IndentToken):
        value = P.indentedTable(key.line, key.col)
      else:
        P.error("Expected value or indented table after ':'")
    else:
      value = P.expression()

    keys.add(key)
    vals.add(value)
    P.skipNewlines()

  if P.check(DedentToken):
    discard P.advance()

  Node(
    kind: TableNode,
    line: line,
    col: col,
    tableKeys: keys,
    tableVals: vals
  )

proc valueExpression(P: Parser): Node =
  let line = P.current.line
  let col = P.current.col

  if P.match(NewlineToken):
    if P.check(IndentToken):
      return P.indentedTable(line, col)
    P.error("Expected expression after newline")

  P.expression()

# Primary expressions
proc primary(P: Parser): Node =
  let line = P.current.line
  let col = P.current.col
  
  if P.match(IntToken):
    return Node(kind: IntLitNode, line: line, col: col, 
                intVal: parseInt(P.previous.lexeme))
  
  if P.match(FloatToken):
    return Node(kind: FloatLitNode, line: line, col: col,
                floatVal: parseFloat(P.previous.lexeme))
  
  if P.match(StringToken):
    return Node(kind: StrLitNode, line: line, col: col,
                strVal: P.previous.lexeme)
  
  if P.match(TrueToken):
    return Node(kind: BoolLitNode, line: line, col: col, boolVal: true)
  
  if P.match(FalseToken):
    return Node(kind: BoolLitNode, line: line, col: col, boolVal: false)
  
  if P.match(NilToken):
    return Node(kind: NilLitNode, line: line, col: col)
  
  if P.match(IdentToken):
    return Node(kind: IdentNode, line: line, col: col, name: P.previous.lexeme)
  
  if P.match(LParenToken):
    let expr = P.expression()
    discard P.consume(RParenToken, "Expected ')' after expression")
    return expr
  
  if P.match(LBracketToken):
    # Array literal
    var elems: seq[Node] = @[]

    P.skipTableLayout()

    if not P.check(RBracketToken):
      elems.add(P.valueExpression())
      P.skipTableLayout()

      while P.match(CommaToken):
        P.skipTableLayout()
        if P.check(RBracketToken):
          break
        elems.add(P.valueExpression())
        P.skipTableLayout()

    discard P.consume(RBracketToken, "Expected ']' after array elements")
    return Node(kind: ArrayNode, line: line, col: col, arrayElems: elems)
  
  if P.match(LBraceToken):
    # Could be a table {key: val} or a set {val, val}
    P.skipTableLayout()

    if P.check(RBraceToken):
      # Empty set {}
      discard P.advance()
      return Node(kind: SetNode, line: line, col: col, setElems: @[])

    let firstExpr = P.expression()
    P.skipTableLayout()

    if P.check(ColonToken):
      # It's a table {key: val, ...}
      discard P.advance()
      var keys = @[firstExpr]
      var vals = @[P.valueExpression()]
      P.skipTableLayout()

      while P.match(CommaToken):
        P.skipTableLayout()
        if P.check(RBraceToken):
          break
        keys.add(P.expression())
        P.skipTableLayout()
        discard P.consume(ColonToken, "Expected ':' after table key")
        vals.add(P.valueExpression())
        P.skipTableLayout()

      discard P.consume(RBraceToken, "Expected '}' after table entries")
      return Node(kind: TableNode, line: line, col: col, tableKeys: keys, tableVals: vals)
    else:
      # It's a set {val, val, ...}
      var elems = @[firstExpr]
      P.skipTableLayout()

      while P.match(CommaToken):
        P.skipTableLayout()
        if P.check(RBraceToken):
          break
        elems.add(P.expression())
        P.skipTableLayout()

      discard P.consume(RBraceToken, "Expected '}' after set elements")
      return Node(kind: SetNode, line: line, col: col, setElems: elems)

  P.error(fmt"Expected expression, got {P.current.kind}")

# Check if current token can start a command-style argument
proc canStartCommandArg(P: Parser): bool =
  case P.current.kind
  of IntToken, FloatToken, StringToken, TrueToken, FalseToken, NilToken,
     IdentToken, LParenToken, LBracketToken, LBraceToken, DollarToken,
     NotToken:
    true
  of MinusToken:
    P.isAttachedToUpcoming()
  else:
    false

proc canBeCommandCallee(node: Node): bool =
  node.kind in {IdentNode, DotNode}

# Call and indexing syntax
proc postfix(P: Parser): Node =
  result = P.primary()
  
  while true:
    let line = P.current.line
    let col = P.current.col
    
    if P.check(LParenToken) and not P.hasCommandGap():
      # Function call with parentheses
      discard P.advance()
      var args: seq[Node] = @[]
      if not P.check(RParenToken):
        args.add(P.expression())
        while P.match(CommaToken):
          if P.check(RParenToken):
            P.error("Expected ')'")
          args.add(P.expression())
      discard P.consume(RParenToken, "Expected ')' after arguments")
      result = Node(kind: CallNode, line: line, col: col, callee: result, args: args)
    elif P.check(LBracketToken) and not P.hasCommandGap():
      # Index access
      discard P.advance()
      let index = P.expression()
      discard P.consume(RBracketToken, "Expected ']' after index")
      result = Node(kind: IndexNode, line: line, col: col, indexee: result, index: index)
    elif P.match(DotToken):
      # Field access or UFCS method call
      let field = P.consume(IdentToken, "Expected field name after '.'")
      result = Node(kind: DotNode, line: line, col: col, dotLeft: result, dotField: field.lexeme)
    else:
      break

# Unary operators
proc unary(P: Parser): Node =
  let line = P.current.line
  let col = P.current.col
  
  if P.match(MinusToken):
    return Node(kind: UnaryOpNode, line: line, col: col, unOp: "-", unOperand: P.unary())
  
  if P.match(NotToken):
    return Node(kind: UnaryOpNode, line: line, col: col, unOp: "not", unOperand: P.unary())
  
  if P.match(DollarToken):
    return Node(kind: UnaryOpNode, line: line, col: col, unOp: "$", unOperand: P.unary())
  
  return P.postfix()

# Range expression
proc rangeExpr(P: Parser): Node =
  result = P.unary()
  
  let line = P.current.line
  let col = P.current.col
  
  if P.match(DotDotToken):
    return Node(kind: RangeNode, line: line, col: col,
                rangeStart: result, rangeEnd: P.unary(), rangeInclusive: true)
  
  if P.match(DotDotLtToken):
    return Node(kind: RangeNode, line: line, col: col,
                rangeStart: result, rangeEnd: P.unary(), rangeInclusive: false)

# Multiplication and division
proc factor(P: Parser): Node =
  result = P.rangeExpr()
  
  while P.checkAny({StarToken, SlashToken, PercentToken}):
    let line = P.current.line
    let col = P.current.col
    let op = P.advance().lexeme
    result = Node(kind: BinaryOpNode, line: line, col: col,
                  binOp: op, binLeft: result, binRight: P.rangeExpr())

# Addition and subtraction
proc term(P: Parser): Node =
  result = P.factor()
  
  while P.checkAny({PlusToken, MinusToken, AmpToken}):
    if P.current.kind == MinusToken and
        canBeCommandCallee(result) and
        P.hasCommandGap() and
        P.isAttachedToUpcoming():
      break
    let line = P.current.line
    let col = P.current.col
    let op = P.advance().lexeme
    result = Node(kind: BinaryOpNode, line: line, col: col,
                  binOp: op, binLeft: result, binRight: P.factor())

# Comparison
proc comparison(P: Parser): Node =
  result = P.term()
  
  while P.checkAny({LtToken, LeToken, GtToken, GeToken, InToken}):
    let line = P.current.line
    let col = P.current.col
    let op = P.advance().lexeme
    result = Node(kind: BinaryOpNode, line: line, col: col,
                  binOp: op, binLeft: result, binRight: P.term())

# Equality
proc equality(P: Parser): Node =
  result = P.comparison()
  
  while P.checkAny({EqEqToken, NotEqToken}):
    let line = P.current.line
    let col = P.current.col
    let op = P.advance().lexeme
    result = Node(kind: BinaryOpNode, line: line, col: col,
                  binOp: op, binLeft: result, binRight: P.comparison())

# Logical AND
proc logicalAnd(P: Parser): Node =
  result = P.equality()
  
  while P.check(AndToken):
    let line = P.current.line
    let col = P.current.col
    discard P.advance()
    result = Node(kind: BinaryOpNode, line: line, col: col,
                  binOp: "and", binLeft: result, binRight: P.equality())

# Logical OR
proc logicalOr(P: Parser): Node =
  result = P.logicalAnd()
  
  while P.check(OrToken):
    let line = P.current.line
    let col = P.current.col
    discard P.advance()
    result = Node(kind: BinaryOpNode, line: line, col: col,
                  binOp: "or", binLeft: result, binRight: P.logicalAnd())

proc commandExpr(P: Parser): Node =
  result = P.logicalOr()

  while canBeCommandCallee(result) and
      P.canStartCommandArg() and
      P.hasCommandGap():
    var args: seq[Node] = @[]
    args.add(P.expression())
    while P.match(CommaToken):
      args.add(P.expression())
    result = Node(
      kind: CallNode,
      line: result.line,
      col: result.col,
      callee: result,
      args: args
    )

proc expression(P: Parser): Node =
  P.commandExpr()

# Parse a block of statements (after indent)
proc parseBlock(P: Parser): Node =
  let line = P.current.line
  let col = P.current.col
  var stmts: seq[Node] = @[]
  
  P.skipNewlines()
  discard P.consume(IndentToken, "Expected indented block")
  P.skipNewlines()
  
  while not P.check(DedentToken) and not P.check(EofToken):
    stmts.add(P.statement())
    P.skipNewlines()
  
  if P.check(DedentToken):
    discard P.advance()
  
  Node(kind: BlockNode, line: line, col: col, stmts: stmts)

# Let statement
proc letStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let name = P.consume(IdentToken, "Expected variable name").lexeme
  discard P.consume(EqToken, "Expected '=' after variable name")
  let value = P.valueExpression()
  
  Node(kind: LetStmtNode, line: line, col: col, varName: name, varValue: value)

# Var statement
proc varStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let name = P.consume(IdentToken, "Expected variable name").lexeme
  var value: Node = nil
  if P.match(EqToken):
    value = P.valueExpression()
  else:
    value = Node(kind: NilLitNode, line: line, col: col)
  
  Node(kind: VarStmtNode, line: line, col: col, varName: name, varValue: value)

# If statement
proc ifStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let cond = P.expression()
  discard P.consume(ColonToken, "Expected ':' after if condition")
  let body = P.parseBlock()
  
  var elifs: seq[Node] = @[]
  var elseBody: Node = nil
  
  P.skipNewlines()
  while P.match(ElifToken):
    let elifLine = P.previous.line
    let elifCol = P.previous.col
    let elifCond = P.expression()
    discard P.consume(ColonToken, "Expected ':' after elif condition")
    let elifBody = P.parseBlock()
    elifs.add(Node(kind: ElifBranchNode, line: elifLine, col: elifCol,
                   elifCond: elifCond, elifBody: elifBody))
    P.skipNewlines()
  
  if P.match(ElseToken):
    discard P.consume(ColonToken, "Expected ':' after else")
    elseBody = P.parseBlock()
  
  Node(kind: IfStmtNode, line: line, col: col,
       ifCond: cond, ifBody: body, elifBranches: elifs, elseBranch: elseBody)

# For statement
proc forStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let varName = P.consume(IdentToken, "Expected loop variable name").lexeme
  discard P.consume(InToken, "Expected 'in' after loop variable")
  let iter = P.expression()
  discard P.consume(ColonToken, "Expected ':' after for iterator")
  let body = P.parseBlock()
  
  Node(kind: ForStmtNode, line: line, col: col,
       forVar: varName, forIter: iter, forBody: body)

# While statement
proc whileStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let cond = P.expression()
  discard P.consume(ColonToken, "Expected ':' after while condition")
  let body = P.parseBlock()
  
  Node(kind: WhileStmtNode, line: line, col: col, whileCond: cond, whileBody: body)

# Proc definition
proc procDef(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let name = P.consume(IdentToken, "Expected procedure name").lexeme
  discard P.consume(LParenToken, "Expected '(' after procedure name")
  
  var params: seq[string] = @[]
  if not P.check(RParenToken):
    params.add(P.consume(IdentToken, "Expected parameter name").lexeme)
    while P.match(CommaToken):
      params.add(P.consume(IdentToken, "Expected parameter name").lexeme)
  
  discard P.consume(RParenToken, "Expected ')' after parameters")
  discard P.consume(EqToken, "Expected '=' after procedure signature")
  let body = P.parseBlock()
  
  Node(kind: ProcDefNode, line: line, col: col,
       procName: name, procParams: params, procBody: body)

# Type definition
proc typeDef(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let name = P.consume(IdentToken, "Expected type name").lexeme
  discard P.consume(EqToken, "Expected '=' after type name")
  discard P.consume(ObjectToken, "Expected 'object' after '='")
  
  P.skipNewlines()
  discard P.consume(IndentToken, "Expected indented block for object fields")
  P.skipNewlines()
  
  var fields: seq[Node] = @[]
  while not P.check(DedentToken) and not P.check(EofToken):
    let fieldLine = P.current.line
    let fieldCol = P.current.col
    let fieldName = P.consume(IdentToken, "Expected field name").lexeme
    fields.add(Node(kind: FieldDefNode, line: fieldLine, col: fieldCol, fieldName: fieldName))
    P.skipNewlines()
  
  if P.check(DedentToken):
    discard P.advance()
  
  let objDef = Node(kind: ObjectDefNode, line: line, col: col, objectFields: fields)
  Node(kind: TypeDefNode, line: line, col: col, typeName: name, typeBody: objDef)

# Return statement
proc returnStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  var value: Node = nil
  if not P.check(NewlineToken) and not P.check(EofToken) and not P.check(DedentToken):
    value = P.expression()
  
  Node(kind: ReturnStmtNode, line: line, col: col, returnValue: value)

# Expression statement or assignment
proc expressionStatement(P: Parser): Node =
  let line = P.current.line
  let col = P.current.col
  let expr = P.expression()
  
  if P.match(EqToken):
    # Assignment
    let value = P.valueExpression()
    return Node(kind: AssignNode, line: line, col: col,
                assignTarget: expr, assignValue: value)
  
  return expr

proc statement(P: Parser): Node =
  P.skipNewlines()
  
  if P.match(LetToken):
    return P.letStatement()
  
  if P.match(VarToken):
    return P.varStatement()
  
  if P.match(IfToken):
    return P.ifStatement()
  
  if P.match(ForToken):
    return P.forStatement()
  
  if P.match(WhileToken):
    return P.whileStatement()
  
  if P.match(ProcToken) or P.match(FuncToken):
    return P.procDef()
  
  if P.match(TypeToken):
    return P.typeDef()
  
  if P.match(ReturnToken):
    return P.returnStatement()
  
  if P.match(BreakToken):
    return Node(kind: BreakStmtNode, line: P.previous.line, col: P.previous.col)
  
  if P.match(ContinueToken):
    return Node(kind: ContinueStmtNode, line: P.previous.line, col: P.previous.col)
  
  return P.expressionStatement()

proc parse*(source: string): Node =
  let P = newParser(source)
  let line = P.current.line
  let col = P.current.col
  var stmts: seq[Node] = @[]
  
  P.skipNewlines()
  while not P.check(EofToken):
    stmts.add(P.statement())
    P.skipNewlines()
  
  Node(kind: ProgramNode, line: line, col: col, stmts: stmts)
