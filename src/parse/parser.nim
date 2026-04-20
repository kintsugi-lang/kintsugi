import std/strutils
import ../core/types
import lexer

type
  Container = object
    kind: ValueKind  # vkBlock or vkParen
    values: seq[KtgValue]
    line: int

const MaxNestingDepth = 256

proc parse*(tokens: seq[KtgValue]): seq[KtgValue] =
  ## Stack-based parser. Nests tokens into blocks and parens.
  var stack: seq[Container] = @[]
  stack.add(Container(kind: vkBlock, values: @[], line: 0))  # root container

  for tok in tokens:
    # open block
    if tok.kind == vkBlock and tok.blockVals.len == 0:
      if stack.len >= MaxNestingDepth:
        raise KtgError(kind: "parse", msg: "Maximum nesting depth (" & $MaxNestingDepth & ") exceeded at line " & $tok.line, data: nil)
      stack.add(Container(kind: vkBlock, values: @[], line: tok.line))
      continue

    # open paren
    if tok.kind == vkParen and tok.parenVals.len == 0:
      if stack.len >= MaxNestingDepth:
        raise KtgError(kind: "parse", msg: "Maximum nesting depth (" & $MaxNestingDepth & ") exceeded at line " & $tok.line, data: nil)
      stack.add(Container(kind: vkParen, values: @[], line: tok.line))
      continue

    # close block
    if tok.kind == vkWord and tok.wordName == "]":
      if stack.len <= 1:
        raise KtgError(kind: "parse", msg: "Unexpected ]", data: nil)
      let top = stack.pop
      if top.kind != vkBlock:
        raise KtgError(kind: "parse", msg: "Mismatched ] — expected )", data: nil)
      let val = ktgBlock(top.values, top.line)
      stack[^1].values.add(val)
      continue

    # close paren
    if tok.kind == vkWord and tok.wordName == ")":
      if stack.len <= 1:
        raise KtgError(kind: "parse", msg: "Unexpected )", data: nil)
      let top = stack.pop
      if top.kind != vkParen:
        raise KtgError(kind: "parse", msg: "Mismatched ) — expected ]", data: nil)
      let val = ktgParen(top.values, top.line)
      stack[^1].values.add(val)
      continue

    # atom — add to current container
    stack[^1].values.add(tok)

  if stack.len > 1:
    let unclosed = stack[^1]
    let bracket = if unclosed.kind == vkBlock: "[" else: "("
    raise KtgError(
      kind: "parse",
      msg: "Unclosed " & bracket & " at line " & $unclosed.line,
      data: nil
    )

  stack[0].values


proc parseSource*(src: string): seq[KtgValue] =
  ## Convenience: lex + parse in one call.
  parse(tokenize(src))

proc stripKintsugiHeader*(ast: seq[KtgValue]): (seq[KtgValue], bool) =
  ## Drop a leading `Kintsugi [...]` entrypoint header from an AST.
  ## Returns (bodyAst, isEntrypoint). Lex-based, so it correctly ignores
  ## bracket characters inside string literals or comments — unlike a
  ## naive character-level bracket counter.
  if ast.len >= 2 and ast[0].kind == vkWord and ast[0].wordKind == wkWord and
     ast[0].wordName.startsWith("Kintsugi") and ast[1].kind == vkBlock:
    return (ast[2 .. ^1], true)
  (ast, false)

proc parseSourceStripped*(src: string): (seq[KtgValue], bool) =
  ## Lex + parse + strip entrypoint header. Returns (bodyAst, isEntrypoint).
  stripKintsugiHeader(parseSource(src))

proc headerTarget*(src: string): string =
  ## Returns the value of `target:` from the Kintsugi header as a bare
  ## name, or "" if no header is present or no target is declared. The
  ## header value must be a lit-word (e.g. `target: 'interpreter`).
  let ast = parseSource(src)
  if ast.len < 2 or ast[0].kind != vkWord or
     not ast[0].wordName.startsWith("Kintsugi") or
     ast[1].kind != vkBlock:
    return ""
  let header = ast[1].blockVals
  var i = 0
  while i < header.len:
    if header[i].kind == vkWord and header[i].wordKind == wkSetWord and
       header[i].wordName == "target" and i + 1 < header.len and
       header[i + 1].kind == vkWord and header[i + 1].wordKind == wkLitWord:
      return header[i + 1].wordName
    i += 1
  ""
