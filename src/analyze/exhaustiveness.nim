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
    acCovers      ## covers one named variant
    acCatchAll    ## catches any remaining variant
    acGuarded     ## pattern could match but has a guard; do not count
    acSkipped     ## unchecked pattern shape (paren, block destructure, etc.)

  ArmInfo = object
    cat: ArmCat
    variant: string  ## populated when cat == acCovers
    line: int

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

proc classifyArm(pattern: KtgValue, hasGuard: bool,
                 enumMode: bool): ArmInfo =
  ## Inspect a single arm's pattern block and categorize it.
  if pattern.kind != vkBlock or pattern.blockVals.len != 1:
    return ArmInfo(cat: acSkipped)
  let elem = pattern.blockVals[0]

  # Wildcard / bare-word capture catches anything remaining.
  if elem.kind == vkWord and elem.wordKind == wkWord:
    if hasGuard:
      return ArmInfo(cat: acGuarded, line: elem.line)
    return ArmInfo(cat: acCatchAll, line: elem.line)

  if enumMode:
    if isLitWord(elem):
      if hasGuard:
        return ArmInfo(cat: acGuarded, line: elem.line)
      return ArmInfo(cat: acCovers, variant: elem.wordName.toLower,
                     line: elem.line)
  else:
    if isTypeWord(elem):
      if hasGuard:
        return ArmInfo(cat: acGuarded, line: elem.line)
      return ArmInfo(cat: acCovers, variant: elem.typeName.toLower,
                     line: elem.line)

  ArmInfo(cat: acSkipped)

proc parseRules(rules: seq[KtgValue], enumMode: bool): seq[ArmInfo] =
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

    result.add(classifyArm(pattern, hasGuard, enumMode))

proc checkArms(arms: seq[ArmInfo], variants: seq[string],
               scrutineeType: string, line: int) =
  var covered: HashSet[string]
  var caughtAll = false
  for a in arms:
    if caughtAll:
      raise KtgError(kind: "match",
        msg: "unreachable match arm: preceding catch-all covers all remaining " &
             scrutineeType & " variants",
        data: nil, line: a.line)
    case a.cat
    of acCovers:
      if a.variant in covered:
        raise KtgError(kind: "match",
          msg: "unreachable match arm: variant '" & a.variant &
               "' of " & scrutineeType & " already covered",
          data: nil, line: a.line)
      covered.incl(a.variant)
      if not (a.variant in variants):
        # Literal/type that doesn't belong to the declared union; skip.
        discard
    of acCatchAll:
      caughtAll = true
    of acGuarded, acSkipped:
      discard

  if caughtAll: return
  var missing: seq[string]
  for v in variants:
    if v notin covered: missing.add(v)
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
  if typeName notin eval.typeEnv: return
  let ct = eval.typeEnv[typeName]

  if ct.isEnum:
    let variants = enumVariants(ct)
    if variants.len == 0: return
    let arms = parseRules(rules, enumMode = true)
    checkArms(arms, variants, typeName, line)
  else:
    let variants = unionVariants(ct)
    if variants.len == 0: return  # guard-types, structs, etc. skipped
    let arms = parseRules(rules, enumMode = false)
    checkArms(arms, variants, typeName, line)

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
