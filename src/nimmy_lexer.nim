## nimmy_lexer.nim
## Tokenizer/Lexer for the Nimmy scripting language

import nimmy_types
import std/[strutils, strformat, tables]

type
  Lexer* = ref object
    source*: string
    pos*: int
    line*: int
    col*: int
    indentStack: seq[int]
    pendingTokens: seq[Token]
    atLineStart: bool

const
  Keywords = {
    "let": tkLet,
    "var": tkVar,
    "proc": tkProc,
    "func": tkFunc,
    "if": tkIf,
    "elif": tkElif,
    "else": tkElse,
    "for": tkFor,
    "while": tkWhile,
    "break": tkBreak,
    "continue": tkContinue,
    "return": tkReturn,
    "in": tkIn,
    "not": tkNot,
    "and": tkAnd,
    "or": tkOr,
    "type": tkType,
    "object": tkObject,
    "true": tkTrue,
    "false": tkFalse,
    "nil": tkNil,
    "echo": tkEcho,
  }.toTable

proc newLexer*(source: string): Lexer =
  Lexer(
    source: source,
    pos: 0,
    line: 1,
    col: 1,
    indentStack: @[0],
    pendingTokens: @[],
    atLineStart: true
  )

proc isAtEnd(L: Lexer): bool =
  L.pos >= L.source.len

proc peek(L: Lexer, offset: int = 0): char =
  let idx = L.pos + offset
  if idx >= L.source.len:
    return '\0'
  result = L.source[idx]

proc advance(L: Lexer): char =
  result = L.source[L.pos]
  L.pos += 1
  if result == '\n':
    L.line += 1
    L.col = 1
  else:
    L.col += 1

proc match(L: Lexer, expected: char): bool =
  if L.isAtEnd or L.source[L.pos] != expected:
    return false
  discard L.advance()
  return true

proc makeToken(L: Lexer, kind: TokenKind, lexeme: string, line, col: int): Token =
  Token(kind: kind, lexeme: lexeme, line: line, col: col)

proc error(L: Lexer, msg: string) =
  var e = newException(LexerError, fmt"{msg} at line {L.line}, column {L.col}")
  e.line = L.line
  e.col = L.col
  raise e

proc skipLineComment(L: Lexer) =
  while not L.isAtEnd and L.peek() != '\n':
    discard L.advance()

proc scanString(L: Lexer): Token =
  let startLine = L.line
  let startCol = L.col
  let quote = L.advance()  # consume opening quote
  var value = ""
  
  while not L.isAtEnd and L.peek() != quote:
    if L.peek() == '\n':
      L.error("Unterminated string")
    if L.peek() == '\\':
      discard L.advance()
      if L.isAtEnd:
        L.error("Unterminated string")
      case L.peek()
      of 'n': value.add('\n')
      of 't': value.add('\t')
      of 'r': value.add('\r')
      of '\\': value.add('\\')
      of '"': value.add('"')
      of '\'': value.add('\'')
      else:
        value.add('\\')
        value.add(L.peek())
      discard L.advance()
    else:
      value.add(L.advance())
  
  if L.isAtEnd:
    L.error("Unterminated string")
  
  discard L.advance()  # consume closing quote
  result = L.makeToken(tkString, value, startLine, startCol)

proc scanNumber(L: Lexer): Token =
  let startLine = L.line
  let startCol = L.col
  var value = ""
  
  while not L.isAtEnd and L.peek().isDigit:
    value.add(L.advance())
  
  var isFloat = false
  if L.peek() == '.' and L.peek(1).isDigit:
    isFloat = true
    value.add(L.advance())  # consume '.'
    while not L.isAtEnd and L.peek().isDigit:
      value.add(L.advance())
  
  if isFloat:
    result = L.makeToken(tkFloat, value, startLine, startCol)
  else:
    result = L.makeToken(tkInt, value, startLine, startCol)

proc scanIdentifier(L: Lexer): Token =
  let startLine = L.line
  let startCol = L.col
  var value = ""
  
  while not L.isAtEnd and (L.peek().isAlphaNumeric or L.peek() == '_'):
    value.add(L.advance())
  
  if Keywords.hasKey(value):
    result = L.makeToken(Keywords[value], value, startLine, startCol)
  else:
    result = L.makeToken(tkIdent, value, startLine, startCol)

proc measureIndent(L: Lexer): int =
  ## Count spaces at the start of the current line
  result = 0
  while L.pos + result < L.source.len and L.source[L.pos + result] == ' ':
    result += 1

proc nextToken*(L: Lexer): Token =
  # Return pending tokens first (dedents, etc.)
  if L.pendingTokens.len > 0:
    result = L.pendingTokens[0]
    L.pendingTokens.delete(0)
    return result
  
  # Handle indentation at line start
  if L.atLineStart:
    L.atLineStart = false
    let indent = L.measureIndent()
    let currentIndent = L.indentStack[^1]
    
    # Skip empty lines and comment-only lines
    var tempPos = L.pos + indent
    while tempPos < L.source.len and L.source[tempPos] in {' ', '\r'}:
      tempPos += 1
    if tempPos < L.source.len and (L.source[tempPos] == '\n' or L.source[tempPos] == '\r' or L.source[tempPos] == '#'):
      # Skip to end of line
      while L.pos < L.source.len and L.peek() != '\n':
        discard L.advance()
      if not L.isAtEnd:
        discard L.advance()  # consume newline
        L.atLineStart = true
      return L.nextToken()
    
    # Consume the indent spaces
    for i in 0..<indent:
      discard L.advance()
    
    if indent > currentIndent:
      L.indentStack.add(indent)
      return L.makeToken(tkIndent, "", L.line, 1)
    elif indent < currentIndent:
      while L.indentStack.len > 1 and L.indentStack[^1] > indent:
        L.pendingTokens.add(L.makeToken(tkDedent, "", L.line, 1))
        discard L.indentStack.pop()
      if L.indentStack[^1] != indent:
        L.error("Inconsistent indentation")
      if L.pendingTokens.len > 0:
        result = L.pendingTokens[0]
        L.pendingTokens.delete(0)
        return result
  
  # Skip whitespace (but not newlines)
  while not L.isAtEnd and L.peek() in {' ', '\t', '\r'}:
    discard L.advance()
  
  # Check for end of file
  if L.isAtEnd:
    # Generate remaining dedents
    while L.indentStack.len > 1:
      L.pendingTokens.add(L.makeToken(tkDedent, "", L.line, L.col))
      discard L.indentStack.pop()
    if L.pendingTokens.len > 0:
      result = L.pendingTokens[0]
      L.pendingTokens.delete(0)
      return result
    return L.makeToken(tkEof, "", L.line, L.col)
  
  let startLine = L.line
  let startCol = L.col
  let c = L.advance()
  
  case c
  of '#':
    L.skipLineComment()
    return L.nextToken()
  
  of '\n':
    L.atLineStart = true
    return L.makeToken(tkNewline, "\\n", startLine, startCol)
  
  of '"', '\'':
    L.pos -= 1
    L.col -= 1
    return L.scanString()
  
  of '+': return L.makeToken(tkPlus, "+", startLine, startCol)
  of '-': return L.makeToken(tkMinus, "-", startLine, startCol)
  of '*': return L.makeToken(tkStar, "*", startLine, startCol)
  of '/': return L.makeToken(tkSlash, "/", startLine, startCol)
  of '%': return L.makeToken(tkPercent, "%", startLine, startCol)
  of '&': return L.makeToken(tkAmp, "&", startLine, startCol)
  
  of '=':
    if L.match('='):
      return L.makeToken(tkEqEq, "==", startLine, startCol)
    else:
      return L.makeToken(tkEq, "=", startLine, startCol)
  
  of '!':
    if L.match('='):
      return L.makeToken(tkNotEq, "!=", startLine, startCol)
    else:
      L.error("Unexpected character '!'")
  
  of '<':
    if L.match('='):
      return L.makeToken(tkLe, "<=", startLine, startCol)
    else:
      return L.makeToken(tkLt, "<", startLine, startCol)
  
  of '>':
    if L.match('='):
      return L.makeToken(tkGe, ">=", startLine, startCol)
    else:
      return L.makeToken(tkGt, ">", startLine, startCol)
  
  of '.':
    if L.match('.'):
      if L.match('<'):
        return L.makeToken(tkDotDotLt, "..<", startLine, startCol)
      else:
        return L.makeToken(tkDotDot, "..", startLine, startCol)
    else:
      return L.makeToken(tkDot, ".", startLine, startCol)
  
  of '(': return L.makeToken(tkLParen, "(", startLine, startCol)
  of ')': return L.makeToken(tkRParen, ")", startLine, startCol)
  of '[': return L.makeToken(tkLBracket, "[", startLine, startCol)
  of ']': return L.makeToken(tkRBracket, "]", startLine, startCol)
  of '{': return L.makeToken(tkLBrace, "{", startLine, startCol)
  of '}': return L.makeToken(tkRBrace, "}", startLine, startCol)
  of ',': return L.makeToken(tkComma, ",", startLine, startCol)
  of ':': return L.makeToken(tkColon, ":", startLine, startCol)
  of ';': return L.makeToken(tkSemicolon, ";", startLine, startCol)
  
  else:
    if c.isDigit:
      L.pos -= 1
      L.col -= 1
      return L.scanNumber()
    elif c.isAlphaAscii or c == '_':
      L.pos -= 1
      L.col -= 1
      return L.scanIdentifier()
    else:
      L.error(fmt"Unexpected character '{c}'")

proc tokenize*(source: string): seq[Token] =
  let L = newLexer(source)
  result = @[]
  while true:
    let tok = L.nextToken()
    result.add(tok)
    if tok.kind == tkEof:
      break
