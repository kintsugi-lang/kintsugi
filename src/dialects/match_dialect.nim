import std/strutils
import ../core/[types, equality]
import ../eval/[dialect, evaluator]

## Match dialect — pattern matching with destructuring.
## Registered as a native function with arity 2: match <value> <rules-block>
##
## The rules block contains [pattern] [handler] pairs.
## Optional `when [guard]` between pattern and handler.
## `default` as a bare word acts as catch-all.
##
## Pattern elements:
##   literal      — matches exactly (integer, float, string, logic)
##   bare word    — captures/binds the matched value
##   type!        — matches any value of that type (integer!, string!, etc.)
##   'word        — matches the literal word symbol
##   _            — wildcard, matches anything, doesn't bind
##   (expr)       — evaluates expr and matches the result literally
##   when [guard] — guard clause evaluated after pattern match
##   default      — fallback if nothing else matched

# Forward declaration for mutual recursion
proc matchBlock(patterns: seq[KtgValue], values: seq[KtgValue],
                bindings: var seq[(string, KtgValue)],
                eval: Evaluator, ctx: KtgContext): bool

proc matchSingleValue(pattern: KtgValue, value: KtgValue,
                      bindings: var seq[(string, KtgValue)],
                      eval: Evaluator, ctx: KtgContext): bool =
  ## Try to match a single pattern element against a single value.
  ## Returns true if matched. Populates bindings for captures.

  case pattern.kind

  # Wildcard: _ matches anything, no binding
  of vkWord:
    if pattern.wordKind == wkWord:
      if pattern.wordName == "_":
        return true
      # Bare word — capture
      bindings.add((pattern.wordName, value))
      return true

    # Lit-word: 'foo matches the word "foo" literally (case-insensitive)
    if pattern.wordKind == wkLitWord:
      if value.kind == vkWord and
         value.wordName.toLowerAscii == pattern.wordName.toLowerAscii:
        return true
      return false

  # Type match: integer!, string!, etc.
  of vkType:
    # Check for custom type first
    if pattern.customType != nil:
      return eval.matchesCustomType(value, pattern.customType, ctx)
    # Check if it's a known custom type in context
    if ctx.has(pattern.typeName):
      let typeVal = ctx.get(pattern.typeName)
      if typeVal.customType != nil:
        return eval.matchesCustomType(value, typeVal.customType, ctx)
    # Built-in type match
    let actual = typeName(value)
    if actual == pattern.typeName:
      return true
    # Also check built-in type unions
    return typeMatchesBuiltin(actual, pattern.typeName)

  # Paren: evaluate and match result literally
  of vkParen:
    let evaluated = eval.evalBlock(pattern.parenVals, ctx)
    return valuesEqual(evaluated, value)

  # Literal values: match by equality
  of vkInteger, vkFloat, vkString, vkLogic, vkNone,
     vkMoney, vkPair, vkTuple, vkDate, vkTime,
     vkFile, vkUrl, vkEmail:
    return valuesEqual(pattern, value)

  # Nested block pattern: destructure into a block value
  of vkBlock:
    if value.kind == vkBlock:
      return matchBlock(pattern.blockVals, value.blockVals, bindings, eval, ctx)
    return false

  else:
    return false


proc matchBlock(patterns: seq[KtgValue], values: seq[KtgValue],
                bindings: var seq[(string, KtgValue)],
                eval: Evaluator, ctx: KtgContext): bool =
  ## Match a sequence of pattern elements against a sequence of values.
  ## Lengths must match exactly (no variadic patterns for now).
  if patterns.len != values.len:
    return false
  for i in 0 ..< patterns.len:
    if not matchSingleValue(patterns[i], values[i], bindings, eval, ctx):
      return false
  return true


proc matchValue(pattern: KtgValue, value: KtgValue,
                bindings: var seq[(string, KtgValue)],
                eval: Evaluator, ctx: KtgContext): bool =
  ## Top-level match: if pattern is a block, destructure against value.
  ## A block pattern with a single element matches a scalar value against that element.
  if pattern.kind == vkBlock:
    let elems = pattern.blockVals
    if value.kind == vkBlock:
      # Both pattern and value are blocks — try destructure first
      if matchBlock(elems, value.blockVals, bindings, eval, ctx):
        return true
      # If destructure failed and pattern is single element, try scalar match
      # (e.g., [_] as catch-all for any block, [x] to capture entire block)
      if elems.len == 1:
        return matchSingleValue(elems[0], value, bindings, eval, ctx)
      return false
    elif elems.len == 1:
      # Single-element block pattern against scalar value
      return matchSingleValue(elems[0], value, bindings, eval, ctx)
    else:
      return false
  # Non-block pattern (shouldn't happen in normal usage, but handle it)
  return matchSingleValue(pattern, value, bindings, eval, ctx)


proc registerMatch*(eval: Evaluator) =
  ## Register `match` as a 2-arity native: match <value> <rules-block>
  let ctx = eval.global

  ctx.set("match", KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: "match", arity: 2, fn: proc(
        args: seq[KtgValue], ep: pointer): KtgValue =
      let eval = cast[Evaluator](ep)
      let value = args[0]
      let rules = args[1]

      if rules.kind != vkBlock:
        raise KtgError(kind: "type",
          msg: "match expects a block of rules as second argument",
          data: rules)

      let rulesData = rules.blockVals
      var pos = 0

      while pos < rulesData.len:
        let current = rulesData[pos]

        # Check for default (bare word)
        if current.kind == vkWord and current.wordKind == wkWord and
           current.wordName == "default":
          pos += 1
          if pos >= rulesData.len:
            raise KtgError(kind: "match",
              msg: "default missing handler block", data: nil)
          let handler = rulesData[pos]
          if handler.kind != vkBlock:
            raise KtgError(kind: "match",
              msg: "default handler must be a block", data: handler)
          return eval.evalBlock(handler.blockVals, eval.currentCtx)

        # Expect a pattern block
        if current.kind != vkBlock:
          raise KtgError(kind: "match",
            msg: "expected pattern block, got " & typeName(current),
            data: current)

        let pattern = current
        pos += 1

        # Check for optional `when [guard]`
        var guardBlock: seq[KtgValue] = @[]
        if pos < rulesData.len and rulesData[pos].kind == vkWord and
           rulesData[pos].wordKind == wkWord and rulesData[pos].wordName == "when":
          pos += 1
          if pos >= rulesData.len or rulesData[pos].kind != vkBlock:
            raise KtgError(kind: "match",
              msg: "when requires a guard block", data: nil)
          guardBlock = rulesData[pos].blockVals
          pos += 1

        # Expect handler block
        if pos >= rulesData.len:
          raise KtgError(kind: "match",
            msg: "pattern missing handler block", data: nil)
        let handler = rulesData[pos]
        if handler.kind != vkBlock:
          raise KtgError(kind: "match",
            msg: "handler must be a block, got " & typeName(handler),
            data: handler)
        pos += 1

        # Try to match the pattern
        var bindings: seq[(string, KtgValue)] = @[]
        if matchValue(pattern, value, bindings, eval, eval.currentCtx):
          # Create child context with captured bindings
          let handlerCtx = eval.currentCtx.child
          for (name, val) in bindings:
            handlerCtx.set(name, val)

          # Evaluate guard if present
          if guardBlock.len > 0:
            let guardResult = eval.evalBlock(guardBlock, handlerCtx)
            if not isTruthy(guardResult):
              continue  # Guard failed, try next pattern

          # Guard passed (or no guard) — evaluate handler
          return eval.evalBlock(handler.blockVals, handlerCtx)

      # No match found, no default
      ktgNone()
    ),
    line: 0))
