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
