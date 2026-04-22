## Static exhaustiveness checks for the `match` dialect.
##
## Runs before eval or emit. For each `match <scrutinee> <rules>` form:
##   - resolve scrutinee's declared type (via enclosing `function` param spec)
##   - if the type is an enum or builtin-typed union, cross-check arms
##   - report missing variants, unreachable arms, duplicates
##
## Types without a declared scrutinee are silently skipped — no false
## positives for dynamic code.

import std/[strutils, sets, tables]
import ../core/types
import ../eval/dialect

type
  ArmCat = enum
    acCovers      ## unguarded arm that covers one named variant
    acCatchAll    ## unguarded pattern that catches any remaining variant
    acGuarded     ## pattern could match, gated by `when`
    acSkipped     ## unchecked pattern shape (paren, block destructure, etc.)

  ArmInfo = object
    cat: ArmCat
    ## Variant name populated for `acCovers` and for `acGuarded` when the
    ## pattern names a specific variant (lit-word in enum mode, type-word
    ## in union mode, leading lit-word in tagged mode). Empty when the
    ## guarded arm is a capture/wildcard, since those don't pin down a
    ## single variant.
    variant: string
    line: int

  AnalyzerMode = enum
    amEnum, amUnion, amTagged

proc isLitWord(v: KtgValue): bool =
  v.kind == vkWord and v.wordKind == wkLitWord

proc isTypeWord(v: KtgValue): bool =
  ## A pattern element that matches a type, e.g. `integer!`, `string!`.
  v.kind == vkType

proc enumVariants(ct: CustomType): seq[string] =
  for rv in ct.rule:
    if rv.kind == vkWord and rv.wordKind == wkLitWord:
      result.add(rv.wordName.toLower)

proc unionVariants(ct: CustomType): seq[string] =
  ## Split the rule on `|` word separators, collect each type name.
  for rv in ct.rule:
    if rv.kind == vkType:
      result.add(rv.typeName.toLower)

proc taggedVariants(ct: CustomType): seq[string] =
  ## Tagged union variant tags (the leading lit-word of each shape block).
  for rv in ct.rule:
    if rv.kind == vkBlock and rv.blockVals.len > 0 and
       rv.blockVals[0].kind == vkWord and rv.blockVals[0].wordKind == wkLitWord:
      result.add(rv.blockVals[0].wordName.toLower)

proc classifyArm(pattern: KtgValue, hasGuard: bool,
                 mode: AnalyzerMode): ArmInfo =
  ## Inspect a single arm's pattern block and categorize it.
  if pattern.kind != vkBlock: return ArmInfo(cat: acSkipped)
  let elems = pattern.blockVals

  # Tagged mode: multi-element patterns `['circle r]` or `['rect w h]`
  # where the leading element is a lit-word naming a variant.
  if mode == amTagged:
    if elems.len == 0: return ArmInfo(cat: acSkipped)
    if elems.len == 1:
      let only = elems[0]
      if only.kind == vkWord and only.wordKind == wkWord:
        if hasGuard:
          return ArmInfo(cat: acGuarded, line: only.line)
        return ArmInfo(cat: acCatchAll, line: only.line)
      return ArmInfo(cat: acSkipped)
    # Multi-element: leading lit-word = variant tag.
    if isLitWord(elems[0]):
      let v = elems[0].wordName.toLower
      if hasGuard:
        return ArmInfo(cat: acGuarded, variant: v, line: elems[0].line)
      return ArmInfo(cat: acCovers, variant: v, line: elems[0].line)
    return ArmInfo(cat: acSkipped)

  if elems.len != 1: return ArmInfo(cat: acSkipped)
  let elem = elems[0]

  # Wildcard / bare-word capture catches anything remaining.
  if elem.kind == vkWord and elem.wordKind == wkWord:
    if hasGuard:
      return ArmInfo(cat: acGuarded, line: elem.line)
    return ArmInfo(cat: acCatchAll, line: elem.line)

  case mode
  of amEnum:
    if isLitWord(elem):
      let v = elem.wordName.toLower
      if hasGuard:
        return ArmInfo(cat: acGuarded, variant: v, line: elem.line)
      return ArmInfo(cat: acCovers, variant: v, line: elem.line)
  of amUnion:
    if isTypeWord(elem):
      let v = elem.typeName.toLower
      if hasGuard:
        return ArmInfo(cat: acGuarded, variant: v, line: elem.line)
      return ArmInfo(cat: acCovers, variant: v, line: elem.line)
  of amTagged: discard  # handled above

  ArmInfo(cat: acSkipped)

proc parseRules(rules: seq[KtgValue], mode: AnalyzerMode): seq[ArmInfo] =
  ## Walk the rules block in arm order. Shape: `[pattern] [when [guard]] [handler]`
  ## or `default [handler]`.
  var pos = 0
  while pos < rules.len:
    let current = rules[pos]

    if current.kind == vkWord and current.wordKind == wkWord and
       current.wordName == "default":
      result.add(ArmInfo(cat: acCatchAll, line: current.line))
      pos += 1
      if pos < rules.len and rules[pos].kind == vkBlock:
        pos += 1
      continue

    if current.kind != vkBlock:
      pos += 1
      continue

    let pattern = current
    pos += 1

    var hasGuard = false
    if pos < rules.len and rules[pos].kind == vkWord and
       rules[pos].wordKind == wkWord and rules[pos].wordName == "when":
      pos += 1
      hasGuard = true
      if pos < rules.len and rules[pos].kind == vkBlock:
        pos += 1

    # Handler block (skip past it).
    if pos < rules.len and rules[pos].kind == vkBlock:
      pos += 1

    result.add(classifyArm(pattern, hasGuard, mode))

proc checkArms(arms: seq[ArmInfo], variants: seq[string],
               scrutineeType: string, line: int) =
  ## Three-state coverage per variant:
  ##   absent       -- never mentioned
  ##   guarded only -- seen via guarded arm(s) only; guard could fail
  ##   fully        -- seen via unguarded arm; variant is covered
  var fully, guardedOnly: HashSet[string]
  var caughtAll = false
  for a in arms:
    if caughtAll:
      raise KtgError(kind: "match",
        msg: "unreachable match arm: preceding catch-all covers all remaining " &
             scrutineeType & " variants",
        data: nil, line: a.line)
    case a.cat
    of acCovers:
      if a.variant in fully:
        raise KtgError(kind: "match",
          msg: "unreachable match arm: variant '" & a.variant &
               "' of " & scrutineeType & " already covered",
          data: nil, line: a.line)
      fully.incl(a.variant)
      guardedOnly.excl(a.variant)
    of acGuarded:
      if a.variant.len > 0 and a.variant in fully:
        raise KtgError(kind: "match",
          msg: "unreachable match arm: variant '" & a.variant &
               "' of " & scrutineeType &
               " already covered by an earlier unguarded arm; " &
               "the guard is never reached",
          data: nil, line: a.line)
      if a.variant.len > 0 and a.variant notin fully:
        guardedOnly.incl(a.variant)
    of acCatchAll:
      caughtAll = true
    of acSkipped:
      discard

  if caughtAll: return
  var missing, guardedMissing: seq[string]
  for v in variants:
    if v in fully: continue
    if v in guardedOnly: guardedMissing.add(v)
    else: missing.add(v)

  if guardedMissing.len > 0:
    raise KtgError(kind: "match",
      msg: "non-exhaustive match on " & scrutineeType &
           ": variant(s) " & guardedMissing.join(", ") &
           " covered only by guarded arm(s). Guards may fall through; " &
           "add an unguarded arm or `default`",
      data: nil, line: line)
  if missing.len > 0:
    raise KtgError(kind: "match",
      msg: "non-exhaustive match on " & scrutineeType &
           "; missing variants: " & missing.join(", ") &
           ". Add arms for each variant or use `default` / `_` to catch the remainder",
      data: nil, line: line)

type
  FnScope = object
    paramTypes: Table[string, string]  ## param name -> declared type name

proc parseParamTypes(spec: seq[KtgValue]): Table[string, string] =
  ## Extract `name [type!]` pairs from a function spec block.
  var i = 0
  while i < spec.len:
    if spec[i].kind == vkWord and spec[i].wordKind == wkWord:
      let pname = spec[i].wordName
      if i + 1 < spec.len and spec[i + 1].kind == vkBlock:
        let tb = spec[i + 1].blockVals
        if tb.len == 1 and tb[0].kind == vkType:
          result[pname] = tb[0].typeName
          i += 2
          continue
    i += 1

proc resolveScrutineeType(scrutinee: KtgValue,
                          scopes: seq[FnScope]): string =
  if scrutinee.kind != vkWord or scrutinee.wordKind != wkWord: return ""
  let name = scrutinee.wordName
  for i in countdown(scopes.high, 0):
    if name in scopes[i].paramTypes:
      return scopes[i].paramTypes[name]
  ""

proc walkMatch(scrutinee: KtgValue, rules: seq[KtgValue],
               scopes: seq[FnScope], eval: Evaluator, line: int) =
  let typeName = resolveScrutineeType(scrutinee, scopes)
  if typeName.len == 0: return
  if typeName notin eval.typeDefs: return
  let td = eval.typeDefs[typeName]
  if td.custom == nil: return

  case td.kind
  of tkEnum:
    let variants = enumVariants(td.custom)
    if variants.len == 0: return
    let arms = parseRules(rules, amEnum)
    checkArms(arms, variants, typeName, line)
  of tkTagged:
    let variants = taggedVariants(td.custom)
    if variants.len == 0: return
    let arms = parseRules(rules, amTagged)
    checkArms(arms, variants, typeName, line)
  of tkUnion:
    let variants = unionVariants(td.custom)
    if variants.len == 0: return
    let arms = parseRules(rules, amUnion)
    checkArms(arms, variants, typeName, line)
  else:
    discard  # guard / struct / objectRef: no variant set to exhaust

proc walkBlock(vals: seq[KtgValue], scopes: var seq[FnScope],
               eval: Evaluator) =
  var i = 0
  while i < vals.len:
    let v = vals[i]

    # `name: function [spec] [body]` — enter new scope.
    if v.kind == vkWord and v.wordKind == wkSetWord and
       i + 3 < vals.len and
       vals[i + 1].kind == vkWord and vals[i + 1].wordKind == wkWord and
       vals[i + 1].wordName == "function" and
       vals[i + 2].kind == vkBlock and vals[i + 3].kind == vkBlock:
      let spec = vals[i + 2].blockVals
      let body = vals[i + 3].blockVals
      var scope = FnScope(paramTypes: parseParamTypes(spec))
      scopes.add(scope)
      walkBlock(body, scopes, eval)
      discard scopes.pop()
      i += 4
      continue

    # `match scrutinee rules` — check.
    if v.kind == vkWord and v.wordKind == wkWord and v.wordName == "match" and
       i + 2 < vals.len and vals[i + 2].kind == vkBlock:
      walkMatch(vals[i + 1], vals[i + 2].blockVals, scopes, eval, v.line)
      # Still recurse into the rules block bodies for nested matches.
      walkBlock(vals[i + 2].blockVals, scopes, eval)
      i += 3
      continue

    case v.kind
    of vkBlock: walkBlock(v.blockVals, scopes, eval)
    of vkParen: walkBlock(v.parenVals, scopes, eval)
    else: discard
    i += 1

proc checkExhaustiveness*(ast: seq[KtgValue], eval: Evaluator) =
  ## Entry point. Raises KtgError(kind: "match") on the first violation.
  var scopes: seq[FnScope]
  walkBlock(ast, scopes, eval)
