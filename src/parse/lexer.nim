import std/[strutils, math]
import ../core/types

type
  Lexer* = object
    src: string
    pos: int
    line: int

proc newLexer*(src: string): Lexer =
  Lexer(src: src, pos: 0, line: 1)

proc atEnd(lex: Lexer): bool = lex.pos >= lex.src.len

proc peek(lex: Lexer): char =
  if lex.atEnd: '\0' else: lex.src[lex.pos]

proc peekAt(lex: Lexer, offset: int): char =
  let i = lex.pos + offset
  if i >= lex.src.len: '\0' else: lex.src[i]

proc advance(lex: var Lexer): char =
  result = lex.src[lex.pos]
  lex.pos += 1
  if result == '\n': lex.line += 1

proc skipWhitespace(lex: var Lexer) =
  while not lex.atEnd:
    let ch = lex.peek
    if ch == ';':
      # comment — skip to end of line
      while not lex.atEnd and lex.peek != '\n':
        discard lex.advance
    elif ch in {' ', '\t', '\r', '\n'}:
      discard lex.advance
    else:
      break

proc isDigit(ch: char): bool = ch in {'0'..'9'}
proc isAlpha(ch: char): bool = ch in {'a'..'z', 'A'..'Z'}
proc isWordChar(ch: char): bool =
  ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '?', '!', '~'}

proc readString(lex: var Lexer): string =
  ## Read a "..." string with escape sequences
  discard lex.advance  # skip opening "
  var s = ""
  while not lex.atEnd:
    let ch = lex.advance
    if ch == '"': return s
    if ch == '\\':
      if lex.atEnd: break
      let esc = lex.advance
      case esc
      of 'n': s &= '\n'
      of 't': s &= '\t'
      of '\\': s &= '\\'
      of '"': s &= '"'
      else: s &= '\\'; s &= esc
    else:
      s &= ch
  raise KtgError(kind: "parse", msg: "Unterminated string", data: nil)

proc readBraceString(lex: var Lexer): string =
  ## Read a {...} multiline string
  discard lex.advance  # skip opening {
  var s = ""
  var depth = 1
  while not lex.atEnd:
    let ch = lex.advance
    if ch == '{': depth += 1
    elif ch == '}':
      depth -= 1
      if depth == 0: return s
    s &= ch
  raise KtgError(kind: "parse", msg: "Unterminated brace string", data: nil)

proc readTime(lex: var Lexer, prefix: string, startLine: int): KtgValue
proc readDate(lex: var Lexer, yearStr: string, startLine: int): KtgValue

proc readNumber(lex: var Lexer): KtgValue =
  let startLine = lex.line
  var numStr = ""
  var hasDot = false
  var dotCount = 0
  var hasX = false

  # optional negative
  if lex.peek == '-':
    numStr &= lex.advance

  while not lex.atEnd:
    let ch = lex.peek
    if isDigit(ch):
      numStr &= lex.advance
    elif ch == '.' and not hasX:
      # peek ahead: is this a tuple (1.2.3) or float (3.14)?
      dotCount += 1
      numStr &= lex.advance
      hasDot = true
    elif ch == 'x' and not hasDot and not hasX:
      # pair: 100x200 or 100x-200
      hasX = true
      numStr &= lex.advance
      # allow negative second component
      if not lex.atEnd and lex.peek == '-':
        numStr &= lex.advance
    elif ch == ':' and not hasDot and not hasX:
      # might be time: 14:30:00
      return lex.readTime(numStr, startLine)
    elif ch == '-' and not hasX and numStr.len == 4 and not hasDot:
      # might be date: 2026-03-15
      return lex.readDate(numStr, startLine)
    else:
      break

  if hasX:
    let parts = numStr.split('x')
    if parts.len == 2:
      return ktgPair(int32(parseInt(parts[0])), int32(parseInt(parts[1])), startLine)

  if dotCount >= 2:
    # tuple: 1.2.3
    var vals: seq[uint8] = @[]
    for part in numStr.split('.'):
      if part.len > 0:
        vals.add(uint8(parseInt(part)))
    return KtgValue(kind: vkTuple, tupleVals: vals, line: startLine)

  if hasDot:
    return ktgFloat(parseFloat(numStr), startLine)

  return ktgInt(parseInt(numStr), startLine)

proc readTime(lex: var Lexer, prefix: string, startLine: int): KtgValue =
  var parts = @[prefix]
  discard lex.advance  # skip first :
  var current = ""
  while not lex.atEnd:
    let ch = lex.peek
    if isDigit(ch):
      current &= lex.advance
    elif ch == ':':
      parts.add(current)
      current = ""
      discard lex.advance
    else:
      break
  parts.add(current)
  let h = if parts.len > 0: uint8(parseInt(parts[0])) else: 0'u8
  let m = if parts.len > 1: uint8(parseInt(parts[1])) else: 0'u8
  let s = if parts.len > 2: uint8(parseInt(parts[2])) else: 0'u8
  KtgValue(kind: vkTime, hour: h, minute: m, second: s, line: startLine)

proc readDate(lex: var Lexer, yearStr: string, startLine: int): KtgValue =
  discard lex.advance  # skip first -
  var monthStr = ""
  while not lex.atEnd and isDigit(lex.peek):
    monthStr &= lex.advance
  if lex.peek == '-':
    discard lex.advance
  var dayStr = ""
  while not lex.atEnd and isDigit(lex.peek):
    dayStr &= lex.advance
  KtgValue(kind: vkDate,
    year: int16(parseInt(yearStr)),
    month: uint8(parseInt(monthStr)),
    day: uint8(parseInt(dayStr)),
    line: startLine)

proc readWord(lex: var Lexer): string =
  var w = ""
  while not lex.atEnd and isWordChar(lex.peek):
    w &= lex.advance
  # consume path segments: word/segment/segment or word/:get-word or word/1
  while not lex.atEnd and lex.peek == '/':
    if lex.peekAt(1).isAlpha:
      w &= lex.advance  # /
      while not lex.atEnd and isWordChar(lex.peek):
        w &= lex.advance
    elif lex.peekAt(1) == ':' and lex.peekAt(2).isAlpha:
      # get-word path segment: /:word
      w &= lex.advance  # /
      w &= lex.advance  # :
      while not lex.atEnd and isWordChar(lex.peek):
        w &= lex.advance
    elif lex.peekAt(1).isDigit:
      # numeric path segment: word/1 (tuple/block indexing)
      w &= lex.advance  # /
      while not lex.atEnd and lex.peek.isDigit:
        w &= lex.advance
    else:
      break
  w

proc readFilePath(lex: var Lexer): string =
  discard lex.advance  # skip %
  # quoted file path: %"path with spaces"
  if not lex.atEnd and lex.peek == '"':
    discard lex.advance  # skip opening "
    var path = ""
    while not lex.atEnd and lex.peek != '"':
      path &= lex.advance
    if not lex.atEnd: discard lex.advance  # skip closing "
    return path
  var path = ""
  while not lex.atEnd and lex.peek notin {' ', '\t', '\r', '\n', ']', ')', '}'}:
    path &= lex.advance
  path

proc readMoney(lex: var Lexer, startLine: int): KtgValue =
  discard lex.advance  # skip $
  var numStr = ""
  while not lex.atEnd and (isDigit(lex.peek) or lex.peek == '.'):
    numStr &= lex.advance
  let f = parseFloat(numStr)
  ktgMoney(int64(round(f * 100.0)), startLine)

proc nextToken*(lex: var Lexer): KtgValue =
  lex.skipWhitespace
  if lex.atEnd: return nil

  let startLine = lex.line
  let ch = lex.peek

  # strings
  if ch == '"': return ktgString(lex.readString, startLine)
  if ch == '{': return ktgString(lex.readBraceString, startLine)

  # blocks and parens
  if ch == '[':
    discard lex.advance
    return KtgValue(kind: vkBlock, blockVals: @[], line: startLine)  # open marker
  if ch == ']':
    discard lex.advance
    return ktgWord("]", wkWord, startLine)  # close marker
  if ch == '(':
    discard lex.advance
    return KtgValue(kind: vkParen, parenVals: @[], line: startLine)  # open marker
  if ch == ')':
    discard lex.advance
    return ktgWord(")", wkWord, startLine)  # close marker

  # money
  if ch == '$':
    return lex.readMoney(startLine)

  # file path vs modulo: % followed by whitespace/end = modulo, anything else = file path
  if ch == '%' and lex.peekAt(1) notin {' ', '\t', '\r', '\n', '\0'}:
    return ktgFile(lex.readFilePath, startLine)

  # numbers (and pair, tuple, date, time)
  if isDigit(ch) or (ch == '-' and lex.peekAt(1).isDigit):
    return lex.readNumber

  # refinement: /word (no space between / and alpha)
  if ch == '/' and isAlpha(lex.peekAt(1)):
    discard lex.advance  # skip /
    let name = lex.readWord
    return ktgWord("/" & name, wkWord, startLine)

  # operators
  if ch in {'+', '*', '/'}:
    discard lex.advance
    return KtgValue(kind: vkOp, opFn: nil, opSymbol: $ch, line: startLine)

  if ch == '=':
    discard lex.advance
    if lex.peek == '=':
      discard lex.advance
      return KtgValue(kind: vkOp, opFn: nil, opSymbol: "==", line: startLine)
    return KtgValue(kind: vkOp, opFn: nil, opSymbol: "=", line: startLine)

  if ch == '<':
    discard lex.advance
    if lex.peek == '>':
      discard lex.advance
      return KtgValue(kind: vkOp, opFn: nil, opSymbol: "<>", line: startLine)
    if lex.peek == '=':
      discard lex.advance
      return KtgValue(kind: vkOp, opFn: nil, opSymbol: "<=", line: startLine)
    return KtgValue(kind: vkOp, opFn: nil, opSymbol: "<", line: startLine)

  if ch == '>':
    discard lex.advance
    if lex.peek == '=':
      discard lex.advance
      return KtgValue(kind: vkOp, opFn: nil, opSymbol: ">=", line: startLine)
    return KtgValue(kind: vkOp, opFn: nil, opSymbol: ">", line: startLine)

  if ch == '%':  # only reached when followed by whitespace/end (file path caught above)
    discard lex.advance
    return KtgValue(kind: vkOp, opFn: nil, opSymbol: "%", line: startLine)

  # chain arrow -> (method call marker)
  if ch == '-' and lex.peekAt(1) == '>':
    discard lex.advance  # -
    discard lex.advance  # >
    return ktgWord("->", wkWord, startLine)

  # minus as operator (not negative number — that's handled in readNumber)
  if ch == '-' and not lex.peekAt(1).isDigit:
    discard lex.advance
    return KtgValue(kind: vkOp, opFn: nil, opSymbol: "-", line: startLine)

  # get-word :word
  if ch == ':' and isAlpha(lex.peekAt(1)):
    discard lex.advance
    let name = lex.readWord
    return ktgWord(name, wkGetWord, startLine)

  # lit-word 'word
  if ch == '\'' and isAlpha(lex.peekAt(1)):
    discard lex.advance
    let name = lex.readWord
    return ktgWord(name, wkLitWord, startLine)

  # meta-word @word
  if ch == '@' and isAlpha(lex.peekAt(1)):
    discard lex.advance
    let name = lex.readWord
    return ktgWord(name, wkMetaWord, startLine)

  # word or set-word
  if isAlpha(ch) or ch == '_':
    let name = lex.readWord

    # check for URL (word followed by ://)
    if lex.peek == ':' and lex.peekAt(1) == '/' and lex.peekAt(2) == '/':
      var url = name
      while not lex.atEnd and lex.peek notin {' ', '\t', '\r', '\n', ']', ')', '}'}:
        url &= lex.advance
      return ktgUrl(url, startLine)

    # check for email — word followed by @ or word.word...@
    # handle dotted local parts: first.last@domain.com
    if lex.peek == '@' or (lex.peek == '.' and not lex.atEnd):
      # speculatively scan ahead for @
      var savedPos = lex.pos
      var savedLine = lex.line
      var localPart = name
      var foundAt = lex.peek == '@'
      if not foundAt:
        # try consuming .word segments looking for @
        var specPos = lex.pos
        var specStr = ""
        while specPos < lex.src.len and lex.src[specPos] == '.':
          specStr &= '.'
          specPos += 1
          while specPos < lex.src.len and isWordChar(lex.src[specPos]):
            specStr &= lex.src[specPos]
            specPos += 1
          if specPos < lex.src.len and lex.src[specPos] == '@':
            # found it — consume up to and including @, then domain
            localPart &= specStr
            lex.pos = specPos
            foundAt = true
            break
        if not foundAt:
          lex.pos = savedPos
          lex.line = savedLine
      if foundAt:
        if lex.peek == '@':
          localPart &= lex.advance  # @
        else:
          localPart &= '@'
          lex.pos += 1  # skip @
        while not lex.atEnd and lex.peek notin {' ', '\t', '\r', '\n', ']', ')', '}'}:
          localPart &= lex.advance
        return ktgEmail(localPart, startLine)

    # set-word: trailing colon
    if lex.peek == ':':
      discard lex.advance
      return ktgWord(name, wkSetWord, startLine)

    # type names (ending in !)
    if name.endsWith("!"):
      return ktgType(name, startLine)

    # keywords
    case name.toLowerAscii
    of "true":   return ktgLogic(true, startLine)
    of "false":  return ktgLogic(false, startLine)
    of "none":   return ktgNone(startLine)
    else:        return ktgWord(name, wkWord, startLine)

  # pipe (used by parse dialect as alternative separator)
  if ch == '|':
    discard lex.advance
    return ktgWord("|", wkWord, startLine)


  # unrecognized — skip and warn
  discard lex.advance
  return lex.nextToken


proc tokenize*(src: string): seq[KtgValue] =
  var lex = newLexer(src)
  var tokens: seq[KtgValue] = @[]
  while true:
    let tok = lex.nextToken
    if tok == nil: break
    tokens.add(tok)
  tokens
