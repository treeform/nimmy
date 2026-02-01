## nimmy_parser.nim
## Parser/AST builder for the Nimmy scripting language

import nimmy_types
import nimmy_lexer
import std/[strformat, strutils]

type
  Parser* = ref object
    lexer: Lexer
    current: Token
    previous: Token

proc newParser*(source: string): Parser =
  let lexer = newLexer(source)
  let current = lexer.nextToken()
  Parser(lexer: lexer, current: current)

proc error(P: Parser, msg: string) =
  var e = newException(ParseError, fmt"{msg} at line {P.current.line}, column {P.current.col}")
  e.line = P.current.line
  e.col = P.current.col
  raise e

proc advance(P: Parser): Token =
  P.previous = P.current
  P.current = P.lexer.nextToken()
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
  while P.check(tkNewline):
    discard P.advance()

# Forward declarations
proc expression(P: Parser): Node
proc statement(P: Parser): Node
proc parseBlock(P: Parser): Node

# Primary expressions
proc primary(P: Parser): Node =
  let line = P.current.line
  let col = P.current.col
  
  if P.match(tkInt):
    return Node(kind: nkIntLit, line: line, col: col, 
                intVal: parseInt(P.previous.lexeme))
  
  if P.match(tkFloat):
    return Node(kind: nkFloatLit, line: line, col: col,
                floatVal: parseFloat(P.previous.lexeme))
  
  if P.match(tkString):
    return Node(kind: nkStrLit, line: line, col: col,
                strVal: P.previous.lexeme)
  
  if P.match(tkTrue):
    return Node(kind: nkBoolLit, line: line, col: col, boolVal: true)
  
  if P.match(tkFalse):
    return Node(kind: nkBoolLit, line: line, col: col, boolVal: false)
  
  if P.match(tkNil):
    return Node(kind: nkNilLit, line: line, col: col)
  
  if P.match(tkIdent):
    return Node(kind: nkIdent, line: line, col: col, name: P.previous.lexeme)
  
  if P.match(tkLParen):
    let expr = P.expression()
    discard P.consume(tkRParen, "Expected ')' after expression")
    return expr
  
  if P.match(tkLBracket):
    # Array literal
    var elems: seq[Node] = @[]
    if not P.check(tkRBracket):
      elems.add(P.expression())
      while P.match(tkComma):
        elems.add(P.expression())
    discard P.consume(tkRBracket, "Expected ']' after array elements")
    return Node(kind: nkArray, line: line, col: col, arrayElems: elems)
  
  if P.match(tkLBrace):
    # Could be a table {key: val} or a set {val, val}
    if P.check(tkRBrace):
      # Empty set {}
      discard P.advance()
      return Node(kind: nkSet, line: line, col: col, setElems: @[])
    let firstExpr = P.expression()
    if P.check(tkColon):
      # It's a table {key: val, ...}
      discard P.advance()
      var keys = @[firstExpr]
      var vals = @[P.expression()]
      while P.match(tkComma):
        keys.add(P.expression())
        discard P.consume(tkColon, "Expected ':' after table key")
        vals.add(P.expression())
      discard P.consume(tkRBrace, "Expected '}' after table entries")
      return Node(kind: nkTable, line: line, col: col, tableKeys: keys, tableVals: vals)
    else:
      # It's a set {val, val, ...}
      var elems = @[firstExpr]
      while P.match(tkComma):
        elems.add(P.expression())
      discard P.consume(tkRBrace, "Expected '}' after set elements")
      return Node(kind: nkSet, line: line, col: col, setElems: elems)
  
  P.error(fmt"Expected expression, got {P.current.kind}")

# Call and indexing
proc postfix(P: Parser): Node =
  result = P.primary()
  
  while true:
    let line = P.current.line
    let col = P.current.col
    
    if P.match(tkLParen):
      # Function call
      var args: seq[Node] = @[]
      if not P.check(tkRParen):
        args.add(P.expression())
        while P.match(tkComma):
          args.add(P.expression())
      discard P.consume(tkRParen, "Expected ')' after arguments")
      result = Node(kind: nkCall, line: line, col: col, callee: result, args: args)
    elif P.match(tkLBracket):
      # Index access
      let index = P.expression()
      discard P.consume(tkRBracket, "Expected ']' after index")
      result = Node(kind: nkIndex, line: line, col: col, indexee: result, index: index)
    elif P.match(tkDot):
      # Field access
      let field = P.consume(tkIdent, "Expected field name after '.'")
      result = Node(kind: nkDot, line: line, col: col, dotLeft: result, dotField: field.lexeme)
    else:
      break

# Unary operators
proc unary(P: Parser): Node =
  let line = P.current.line
  let col = P.current.col
  
  if P.match(tkMinus):
    return Node(kind: nkUnaryOp, line: line, col: col, unOp: "-", unOperand: P.unary())
  
  if P.match(tkNot):
    return Node(kind: nkUnaryOp, line: line, col: col, unOp: "not", unOperand: P.unary())
  
  return P.postfix()

# Range expression
proc rangeExpr(P: Parser): Node =
  result = P.unary()
  
  let line = P.current.line
  let col = P.current.col
  
  if P.match(tkDotDot):
    return Node(kind: nkRange, line: line, col: col,
                rangeStart: result, rangeEnd: P.unary(), rangeInclusive: true)
  
  if P.match(tkDotDotLt):
    return Node(kind: nkRange, line: line, col: col,
                rangeStart: result, rangeEnd: P.unary(), rangeInclusive: false)

# Multiplication and division
proc factor(P: Parser): Node =
  result = P.rangeExpr()
  
  while P.checkAny({tkStar, tkSlash, tkPercent}):
    let line = P.current.line
    let col = P.current.col
    let op = P.advance().lexeme
    result = Node(kind: nkBinaryOp, line: line, col: col,
                  binOp: op, binLeft: result, binRight: P.rangeExpr())

# Addition and subtraction
proc term(P: Parser): Node =
  result = P.factor()
  
  while P.checkAny({tkPlus, tkMinus, tkAmp}):
    let line = P.current.line
    let col = P.current.col
    let op = P.advance().lexeme
    result = Node(kind: nkBinaryOp, line: line, col: col,
                  binOp: op, binLeft: result, binRight: P.factor())

# Comparison
proc comparison(P: Parser): Node =
  result = P.term()
  
  while P.checkAny({tkLt, tkLe, tkGt, tkGe, tkIn}):
    let line = P.current.line
    let col = P.current.col
    let op = P.advance().lexeme
    result = Node(kind: nkBinaryOp, line: line, col: col,
                  binOp: op, binLeft: result, binRight: P.term())

# Equality
proc equality(P: Parser): Node =
  result = P.comparison()
  
  while P.checkAny({tkEqEq, tkNotEq}):
    let line = P.current.line
    let col = P.current.col
    let op = P.advance().lexeme
    result = Node(kind: nkBinaryOp, line: line, col: col,
                  binOp: op, binLeft: result, binRight: P.comparison())

# Logical AND
proc logicalAnd(P: Parser): Node =
  result = P.equality()
  
  while P.check(tkAnd):
    let line = P.current.line
    let col = P.current.col
    discard P.advance()
    result = Node(kind: nkBinaryOp, line: line, col: col,
                  binOp: "and", binLeft: result, binRight: P.equality())

# Logical OR
proc logicalOr(P: Parser): Node =
  result = P.logicalAnd()
  
  while P.check(tkOr):
    let line = P.current.line
    let col = P.current.col
    discard P.advance()
    result = Node(kind: nkBinaryOp, line: line, col: col,
                  binOp: "or", binLeft: result, binRight: P.logicalAnd())

proc expression(P: Parser): Node =
  P.logicalOr()

# Parse a block of statements (after indent)
proc parseBlock(P: Parser): Node =
  let line = P.current.line
  let col = P.current.col
  var stmts: seq[Node] = @[]
  
  P.skipNewlines()
  discard P.consume(tkIndent, "Expected indented block")
  P.skipNewlines()
  
  while not P.check(tkDedent) and not P.check(tkEof):
    stmts.add(P.statement())
    P.skipNewlines()
  
  if P.check(tkDedent):
    discard P.advance()
  
  Node(kind: nkBlock, line: line, col: col, stmts: stmts)

# Let statement
proc letStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let name = P.consume(tkIdent, "Expected variable name").lexeme
  discard P.consume(tkEq, "Expected '=' after variable name")
  let value = P.expression()
  
  Node(kind: nkLetStmt, line: line, col: col, varName: name, varValue: value)

# Var statement
proc varStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let name = P.consume(tkIdent, "Expected variable name").lexeme
  var value: Node = nil
  if P.match(tkEq):
    value = P.expression()
  else:
    value = Node(kind: nkNilLit, line: line, col: col)
  
  Node(kind: nkVarStmt, line: line, col: col, varName: name, varValue: value)

# If statement
proc ifStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let cond = P.expression()
  discard P.consume(tkColon, "Expected ':' after if condition")
  let body = P.parseBlock()
  
  var elifs: seq[Node] = @[]
  var elseBody: Node = nil
  
  P.skipNewlines()
  while P.match(tkElif):
    let elifLine = P.previous.line
    let elifCol = P.previous.col
    let elifCond = P.expression()
    discard P.consume(tkColon, "Expected ':' after elif condition")
    let elifBody = P.parseBlock()
    elifs.add(Node(kind: nkElifBranch, line: elifLine, col: elifCol,
                   elifCond: elifCond, elifBody: elifBody))
    P.skipNewlines()
  
  if P.match(tkElse):
    discard P.consume(tkColon, "Expected ':' after else")
    elseBody = P.parseBlock()
  
  Node(kind: nkIfStmt, line: line, col: col,
       ifCond: cond, ifBody: body, elifBranches: elifs, elseBranch: elseBody)

# For statement
proc forStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let varName = P.consume(tkIdent, "Expected loop variable name").lexeme
  discard P.consume(tkIn, "Expected 'in' after loop variable")
  let iter = P.expression()
  discard P.consume(tkColon, "Expected ':' after for iterator")
  let body = P.parseBlock()
  
  Node(kind: nkForStmt, line: line, col: col,
       forVar: varName, forIter: iter, forBody: body)

# While statement
proc whileStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let cond = P.expression()
  discard P.consume(tkColon, "Expected ':' after while condition")
  let body = P.parseBlock()
  
  Node(kind: nkWhileStmt, line: line, col: col, whileCond: cond, whileBody: body)

# Proc definition
proc procDef(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let name = P.consume(tkIdent, "Expected procedure name").lexeme
  discard P.consume(tkLParen, "Expected '(' after procedure name")
  
  var params: seq[string] = @[]
  if not P.check(tkRParen):
    params.add(P.consume(tkIdent, "Expected parameter name").lexeme)
    while P.match(tkComma):
      params.add(P.consume(tkIdent, "Expected parameter name").lexeme)
  
  discard P.consume(tkRParen, "Expected ')' after parameters")
  discard P.consume(tkEq, "Expected '=' after procedure signature")
  let body = P.parseBlock()
  
  Node(kind: nkProcDef, line: line, col: col,
       procName: name, procParams: params, procBody: body)

# Type definition
proc typeDef(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  let name = P.consume(tkIdent, "Expected type name").lexeme
  discard P.consume(tkEq, "Expected '=' after type name")
  discard P.consume(tkObject, "Expected 'object' after '='")
  
  P.skipNewlines()
  discard P.consume(tkIndent, "Expected indented block for object fields")
  P.skipNewlines()
  
  var fields: seq[Node] = @[]
  while not P.check(tkDedent) and not P.check(tkEof):
    let fieldLine = P.current.line
    let fieldCol = P.current.col
    let fieldName = P.consume(tkIdent, "Expected field name").lexeme
    fields.add(Node(kind: nkFieldDef, line: fieldLine, col: fieldCol, fieldName: fieldName))
    P.skipNewlines()
  
  if P.check(tkDedent):
    discard P.advance()
  
  let objDef = Node(kind: nkObjectDef, line: line, col: col, objectFields: fields)
  Node(kind: nkTypeDef, line: line, col: col, typeName: name, typeBody: objDef)

# Return statement
proc returnStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  var value: Node = nil
  if not P.check(tkNewline) and not P.check(tkEof) and not P.check(tkDedent):
    value = P.expression()
  
  Node(kind: nkReturnStmt, line: line, col: col, returnValue: value)

# Echo statement
proc echoStatement(P: Parser): Node =
  let line = P.previous.line
  let col = P.previous.col
  
  var args: seq[Node] = @[]
  if not P.check(tkNewline) and not P.check(tkEof):
    args.add(P.expression())
    while P.match(tkComma):
      args.add(P.expression())
  
  Node(kind: nkEchoStmt, line: line, col: col, echoArgs: args)

# Expression statement or assignment
proc expressionStatement(P: Parser): Node =
  let line = P.current.line
  let col = P.current.col
  let expr = P.expression()
  
  if P.match(tkEq):
    # Assignment
    let value = P.expression()
    return Node(kind: nkAssign, line: line, col: col,
                assignTarget: expr, assignValue: value)
  
  return expr

proc statement(P: Parser): Node =
  P.skipNewlines()
  
  if P.match(tkLet):
    return P.letStatement()
  
  if P.match(tkVar):
    return P.varStatement()
  
  if P.match(tkIf):
    return P.ifStatement()
  
  if P.match(tkFor):
    return P.forStatement()
  
  if P.match(tkWhile):
    return P.whileStatement()
  
  if P.match(tkProc) or P.match(tkFunc):
    return P.procDef()
  
  if P.match(tkType):
    return P.typeDef()
  
  if P.match(tkReturn):
    return P.returnStatement()
  
  if P.match(tkBreak):
    return Node(kind: nkBreakStmt, line: P.previous.line, col: P.previous.col)
  
  if P.match(tkContinue):
    return Node(kind: nkContinueStmt, line: P.previous.line, col: P.previous.col)
  
  if P.match(tkEcho):
    return P.echoStatement()
  
  return P.expressionStatement()

proc parse*(source: string): Node =
  let P = newParser(source)
  let line = P.current.line
  let col = P.current.col
  var stmts: seq[Node] = @[]
  
  P.skipNewlines()
  while not P.check(tkEof):
    stmts.add(P.statement())
    P.skipNewlines()
  
  Node(kind: nkProgram, line: line, col: col, stmts: stmts)
