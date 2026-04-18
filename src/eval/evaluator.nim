import std/[strutils, tables, math, sets]
import ../core/[types, equality, lifecycle]
import ../parse/parser
import dialect, stdlib_registry
import ../dialects/game_dialect

export Evaluator

proc daysInMonth(year: int, month: int): int =
  ## Days in a given month, accounting for leap years.
  case month
  of 1, 3, 5, 7, 8, 10, 12: 31
  of 4, 6, 9, 11: 30
  of 2:
    let leap = (year mod 4 == 0 and year mod 100 != 0) or year mod 400 == 0
    if leap: 29 else: 28
  else: 0

proc intRhs(rhs: KtgValue, label: string): int64 =
  ## Pull an integer out of a set-path RHS for value-type components that only
  ## accept whole numbers (money cents, tuple byte, date/time fields).
  if rhs.kind != vkInteger:
    raise KtgError(kind: "type",
      msg: label & " must be integer!, got " & typeName(rhs), data: rhs)
  rhs.intVal

proc buildValueTypeRebind(current: KtgValue, seg: string,
                          rhs: KtgValue, line: int): KtgValue =
  ## Given a value-type `current` and a field `seg`, produce a new value
  ## of the same type with that component replaced by `rhs`. Validates
  ## ranges and value-type-specific invariants (leap years, 0-59, etc.).
  case current.kind
  of vkPair:
    if seg != "x" and seg != "y":
      raise KtgError(kind: "undefined",
        msg: seg & " not found on pair! (use /x or /y)", data: nil)
    let v =
      if rhs.kind == vkInteger: float64(rhs.intVal)
      elif rhs.kind == vkFloat: rhs.floatVal
      else:
        raise KtgError(kind: "type",
          msg: "pair! field must be integer! or float!, got " & typeName(rhs),
          data: rhs)
    if seg == "x": ktgPair(v, current.py, line)
    else: ktgPair(current.px, v, line)
  of vkMoney:
    if seg != "cents":
      raise KtgError(kind: "undefined",
        msg: seg & " not found on money! (use /cents)", data: nil)
    KtgValue(kind: vkMoney, cents: intRhs(rhs, "money!/cents"), line: line)
  of vkTuple:
    ## Numeric index; validate against current length and 0-255 byte range.
    let idx =
      try: parseInt(seg)
      except ValueError:
        raise KtgError(kind: "undefined",
          msg: seg & " not found on tuple! (use /1, /2, etc.)", data: nil)
    if idx < 1 or idx > current.tupleVals.len:
      raise KtgError(kind: "range",
        msg: "tuple index " & seg & " out of range", data: nil)
    let v = intRhs(rhs, "tuple!/" & seg)
    if v < 0 or v > 255:
      raise KtgError(kind: "range",
        msg: "tuple component must be 0..255, got " & $v, data: rhs)
    var newVals = current.tupleVals
    newVals[idx - 1] = uint8(v)
    KtgValue(kind: vkTuple, tupleVals: newVals, line: line)
  of vkDate:
    var year = int(current.year)
    var month = int(current.month)
    var day = int(current.day)
    let v = intRhs(rhs, "date!/" & seg)
    case seg
    of "year":
      if v < int(int16.low) or v > int(int16.high):
        raise KtgError(kind: "range", msg: "year out of range", data: rhs)
      year = int(v)
    of "month":
      if v < 1 or v > 12:
        raise KtgError(kind: "range", msg: "month must be 1..12, got " & $v, data: rhs)
      month = int(v)
    of "day":
      if v < 1:
        raise KtgError(kind: "range", msg: "day must be >= 1, got " & $v, data: rhs)
      day = int(v)
    else:
      raise KtgError(kind: "undefined",
        msg: seg & " not found on date! (use /year, /month, /day)", data: nil)
    if day > daysInMonth(year, month):
      raise KtgError(kind: "range",
        msg: "day " & $day & " is invalid for " & $year & "-" & $month, data: rhs)
    KtgValue(kind: vkDate, year: int16(year), month: uint8(month),
             day: uint8(day), line: line)
  of vkTime:
    var hour = int(current.hour)
    var minute = int(current.minute)
    var second = int(current.second)
    let v = intRhs(rhs, "time!/" & seg)
    case seg
    of "hour":
      if v < 0 or v > 23:
        raise KtgError(kind: "range", msg: "hour must be 0..23, got " & $v, data: rhs)
      hour = int(v)
    of "minute":
      if v < 0 or v > 59:
        raise KtgError(kind: "range", msg: "minute must be 0..59, got " & $v, data: rhs)
      minute = int(v)
    of "second":
      if v < 0 or v > 59:
        raise KtgError(kind: "range", msg: "second must be 0..59, got " & $v, data: rhs)
      second = int(v)
    else:
      raise KtgError(kind: "undefined",
        msg: seg & " not found on time! (use /hour, /minute, /second)", data: nil)
    KtgValue(kind: vkTime, hour: uint8(hour), minute: uint8(minute),
             second: uint8(second), line: line)
  else:
    raise KtgError(kind: "type",
      msg: "cannot rebind field on " & typeName(current), data: current)

proc toKebabCase*(name: string): string =
  ## Convert PascalCase to kebab-case: "CardReader" -> "card-reader"
  result = ""
  for i, c in name:
    if c.isUpperAscii:
      if i > 0:
        result &= '-'
      result &= c.toLowerAscii
    else:
      result &= c

# Forward declarations
proc evalBlock*(eval: Evaluator, vals: seq[KtgValue], ctx: KtgContext): KtgValue
proc evalNext*(eval: Evaluator, vals: seq[KtgValue], pos: var int, ctx: KtgContext): KtgValue
proc callCallable*(eval: Evaluator, fn: KtgValue, vals: seq[KtgValue],
                   pos: var int, ctx: KtgContext, selfVal: KtgValue = nil): KtgValue

type
  ReturnSignal* = ref object of CatchableError
    value*: KtgValue
  BreakSignal* = ref object of CatchableError
  ExitSignal* = ref object of CatchableError
    code*: int


# --- Evaluator creation ---

proc newEvaluator*(): Evaluator =
  let ctx = newContext()
  result = Evaluator(
    global: ctx,
    currentCtx: ctx,
    output: @[],
    callStack: @[],
    dialects: @[],
    moduleCache: initTable[string, KtgValue](),
    moduleLoading: initHashSet[string](),
    typeEnv: initTable[string, CustomType]()
  )

proc registerDialect*(eval: Evaluator, d: Dialect) =
  eval.dialects.add(d)

proc findDialect*(eval: Evaluator, name: string): Dialect =
  for d in eval.dialects:
    if d.name == name: return d
  nil


# --- Infix handling ---

proc safeMulMoney(a, b: int64): int64 =
  result = a * b
  if a != 0 and result div a != b:
    raise KtgError(kind: "math", msg: "money overflow", data: nil)

proc compareValues*(left, right: KtgValue): int =
  ## Compare two values. Returns negative, 0, or positive.
  ## Raises KtgError if types are not comparable.
  if left.kind in {vkInteger, vkFloat} and right.kind in {vkInteger, vkFloat}:
    let lf = if left.kind == vkInteger: float64(left.intVal) else: left.floatVal
    let rf = if right.kind == vkInteger: float64(right.intVal) else: right.floatVal
    return cmp(lf, rf)
  if left.kind == vkString and right.kind == vkString:
    return cmp(left.strVal, right.strVal)
  if left.kind == vkMoney and right.kind == vkMoney:
    return cmp(left.cents, right.cents)
  if left.kind == vkDate and right.kind == vkDate:
    return cmp(
      (left.year, left.month, left.day),
      (right.year, right.month, right.day))
  if left.kind == vkTime and right.kind == vkTime:
    return cmp(
      (left.hour, left.minute, left.second),
      (right.hour, right.minute, right.second))
  raise KtgError(
    kind: "type",
    msg: "cannot compare " & typeName(left) & " and " & typeName(right),
    data: nil)


proc applyOp*(eval: Evaluator, op: string, left, right: KtgValue): KtgValue =
  # numeric ops
  if left.kind in {vkInteger, vkFloat} and right.kind in {vkInteger, vkFloat}:
    let lf = if left.kind == vkInteger: float64(left.intVal) else: left.floatVal
    let rf = if right.kind == vkInteger: float64(right.intVal) else: right.floatVal

    case op
    of "+":
      if left.kind == vkInteger and right.kind == vkInteger:
        return ktgInt(left.intVal + right.intVal)
      return ktgFloat(lf + rf)
    of "-":
      if left.kind == vkInteger and right.kind == vkInteger:
        return ktgInt(left.intVal - right.intVal)
      return ktgFloat(lf - rf)
    of "*":
      if left.kind == vkInteger and right.kind == vkInteger:
        return ktgInt(left.intVal * right.intVal)
      return ktgFloat(lf * rf)
    of "/":
      if rf == 0.0:
        raise KtgError(kind: "math", msg: "division by zero", data: nil)
      if left.kind == vkInteger and right.kind == vkInteger and
         left.intVal mod right.intVal == 0:
        return ktgInt(left.intVal div right.intVal)
      return ktgFloat(lf / rf)
    of "%":
      if rf == 0.0:
        raise KtgError(kind: "math", msg: "modulo by zero", data: nil)
      if left.kind == vkInteger and right.kind == vkInteger:
        return ktgInt(left.intVal mod right.intVal)
      return ktgFloat(lf - floor(lf / rf) * rf)
    else: discard

  # money ops
  if left.kind == vkMoney and right.kind == vkMoney:
    case op
    of "+": return ktgMoney(left.cents + right.cents)
    of "-": return ktgMoney(left.cents - right.cents)
    else: discard

  if left.kind == vkMoney and right.kind == vkInteger:
    case op
    of "*": return ktgMoney(safeMulMoney(left.cents, right.intVal))
    of "/":
      if right.intVal == 0: raise KtgError(kind: "math", msg: "division by zero", data: nil)
      return ktgMoney(left.cents div right.intVal)
    else: discard

  if left.kind == vkInteger and right.kind == vkMoney:
    case op
    of "*": return ktgMoney(safeMulMoney(left.intVal, right.cents))
    else: discard

  if left.kind == vkMoney and right.kind == vkFloat:
    case op
    of "*": return ktgMoney(int64(round(float64(left.cents) * right.floatVal)))
    of "/":
      if right.floatVal == 0.0: raise KtgError(kind: "math", msg: "division by zero", data: nil)
      return ktgMoney(int64(round(float64(left.cents) / right.floatVal)))
    else: discard

  if left.kind == vkFloat and right.kind == vkMoney:
    case op
    of "*": return ktgMoney(int64(round(left.floatVal * float64(right.cents))))
    else: discard

  # pair ops
  if left.kind == vkPair and right.kind == vkPair:
    case op
    of "+": return ktgPair(left.px + right.px, left.py + right.py)
    of "-": return ktgPair(left.px - right.px, left.py - right.py)
    else: discard

  # pair <op> scalar (and scalar * pair)
  proc scalarOf(v: KtgValue): float64 =
    if v.kind == vkInteger: float64(v.intVal)
    elif v.kind == vkFloat: v.floatVal
    else: NaN
  if left.kind == vkPair and right.kind in {vkInteger, vkFloat}:
    let s = scalarOf(right)
    case op
    of "*": return ktgPair(left.px * s, left.py * s)
    of "/":
      if s == 0: raise KtgError(kind: "math", msg: "pair division by zero", data: right)
      return ktgPair(left.px / s, left.py / s)
    else: discard
  if left.kind in {vkInteger, vkFloat} and right.kind == vkPair:
    let s = scalarOf(left)
    case op
    of "*": return ktgPair(right.px * s, right.py * s)
    else: discard

  # comparison ops
  case op
  of "=":  return ktgLogic(valuesEqual(left, right))
  of "==":
    const nonScalar = {vkBlock, vkParen, vkMap, vkSet, vkContext, vkObject,
                       vkFunction, vkNative, vkOp}
    if left.kind in nonScalar or right.kind in nonScalar:
      raise KtgError(kind: "type",
        msg: "== requires scalar types, got " & typeName(left) & " and " & typeName(right),
        data: nil)
    return ktgLogic(left.kind == right.kind and valuesEqual(left, right))
  of "<>": return ktgLogic(not valuesEqual(left, right))
  of "<":  return ktgLogic(compareValues(left, right) < 0)
  of ">":  return ktgLogic(compareValues(left, right) > 0)
  of "<=": return ktgLogic(compareValues(left, right) <= 0)
  of ">=": return ktgLogic(compareValues(left, right) >= 0)
  else: discard  # arithmetic ops not handled above

  raise KtgError(
    kind: "type",
    msg: "cannot apply " & op & " to " & typeName(left) & " and " & typeName(right),
    data: nil
  )


proc applyInfix*(eval: Evaluator, result: var KtgValue,
                 vals: seq[KtgValue], pos: var int, ctx: KtgContext) =
  ## Left-to-right, no precedence. Consume infix ops while they follow.
  while pos < vals.len:
    let next = vals[pos]

    # chain arrow -> (method call)
    if next.kind == vkWord and next.wordName == "->":
      pos += 1
      if pos >= vals.len or vals[pos].kind != vkWord:
        raise KtgError(kind: "type", msg: "-> expects a method name", data: nil)
      let methodName = vals[pos].wordName
      pos += 1
      var methodFn: KtgValue
      if result.kind == vkContext:
        methodFn = result.ctx.get(methodName)
      elif result.kind == vkObject:
        methodFn = result.obj.get(methodName)
      else:
        raise KtgError(kind: "type",
          msg: "-> requires context! or object!, got " & typeName(result),
          data: result)
      result = eval.callCallable(methodFn, vals, pos, ctx, result)
      continue

    # operator
    if next.kind == vkOp:
      pos += 1
      let right = eval.evalNext(vals, pos, ctx)
      let opSym = next.opSymbol
      result = eval.applyOp(opSym, result, right)
      continue

    # infix words: and, or
    if next.kind == vkWord and next.wordName in ["and", "or"]:
      pos += 1
      let right = eval.evalNext(vals, pos, ctx)
      case next.wordName
      of "and":
        if isTruthy(result):
          result = right
      of "or":
        if not isTruthy(result):
          result = right
      else: discard
      continue

    break


# --- Path navigation ---

proc navigatePath*(eval: Evaluator, head: KtgValue, segments: seq[string],
                   ctx: KtgContext, pathWord: string = ""): KtgValue =
  var current = head
  for seg in segments:
    try:
      # Dynamic get-word segment: :name → evaluate name, use result as index
      if seg.startsWith(":"):
        let varName = seg[1..^1]
        let idx = ctx.get(varName)
        if current.kind == vkBlock:
          if idx.kind == vkInteger:
            let i = int(idx.intVal)
            if i >= 1 and i <= current.blockVals.len:
              current = current.blockVals[i - 1]
            else:
              raise KtgError(kind: "range",
                msg: "index " & $i & " out of range (1.." & $current.blockVals.len & ")",
                data: idx)
          else:
            raise KtgError(kind: "type",
              msg: "block index must be integer!, got " & typeName(idx), data: idx)
        elif current.kind == vkMap:
          let key = $idx
          if key in current.mapEntries:
            current = current.mapEntries[key]
          else:
            raise KtgError(kind: "undefined",
              msg: key & " not found in map", data: idx)
        elif current.kind == vkContext:
          let key = $idx
          current = current.ctx.get(key)
        elif current.kind == vkObject:
          let key = $idx
          current = current.obj.get(key)
        else:
          raise KtgError(kind: "type",
            msg: "cannot index " & typeName(current) & " with dynamic path", data: idx)
      # Static word segment: literal field lookup
      elif current.kind == vkContext:
        current = current.ctx.get(seg)
      elif current.kind == vkObject:
        current = current.obj.get(seg)
      elif current.kind == vkMap:
        if seg in current.mapEntries:
          current = current.mapEntries[seg]
        else:
          raise KtgError(kind: "undefined", msg: seg & " not found in map", data: nil)
      elif current.kind == vkPair:
        case seg
        of "x": current = numFromFloat(current.px)
        of "y": current = numFromFloat(current.py)
        else:
          raise KtgError(kind: "undefined", msg: seg & " not found on pair! (use /x or /y)", data: nil)
      elif current.kind == vkTuple:
        # tuple/1, tuple/2, tuple/3 for indexed access
        try:
          let idx = parseInt(seg)
          if idx >= 1 and idx <= current.tupleVals.len:
            current = ktgInt(int64(current.tupleVals[idx - 1]))
          else:
            raise KtgError(kind: "range", msg: "tuple index " & seg & " out of range", data: nil)
        except ValueError:
          raise KtgError(kind: "undefined", msg: seg & " not found on tuple! (use /1, /2, etc.)", data: nil)
      elif current.kind == vkMoney:
        case seg
        of "cents": current = ktgInt(current.cents)
        else:
          raise KtgError(kind: "undefined", msg: seg & " not found on money! (use /cents)", data: nil)
      elif current.kind == vkDate:
        case seg
        of "year":  current = ktgInt(int64(current.year))
        of "month": current = ktgInt(int64(current.month))
        of "day":   current = ktgInt(int64(current.day))
        else:
          raise KtgError(kind: "undefined",
            msg: seg & " not found on date! (use /year, /month, /day)", data: nil)
      elif current.kind == vkTime:
        case seg
        of "hour":   current = ktgInt(int64(current.hour))
        of "minute": current = ktgInt(int64(current.minute))
        of "second": current = ktgInt(int64(current.second))
        else:
          raise KtgError(kind: "undefined",
            msg: seg & " not found on time! (use /hour, /minute, /second)", data: nil)
      else:
        raise KtgError(kind: "type",
          msg: "cannot navigate path on " & typeName(current), data: nil)
    except KtgError as e:
      if e.path.len == 0 and pathWord.len > 0:
        e.path = pathWord
        e.pathSeg = seg
      raise
  current


proc parsePath*(word: string): (string, seq[string]) =
  ## Split "obj/field/sub" into ("obj", @["field", "sub"])
  let parts = word.split('/')
  (parts[0], parts[1..^1])


# --- Forward declarations for type checking ---
proc typeMatches*(eval: Evaluator, actual, expected: string, value: KtgValue, ctx: KtgContext): bool

# --- Core evaluation ---

proc evalNext*(eval: Evaluator, vals: seq[KtgValue], pos: var int,
               ctx: KtgContext): KtgValue =
  if pos >= vals.len:
    return ktgNone()

  let val = vals[pos]
  pos += 1

  case val.kind

  # --- Scalars: return self ---
  of vkInteger, vkFloat, vkLogic, vkNone,
     vkMoney, vkPair, vkTuple, vkDate, vkTime,
     vkFile, vkUrl, vkEmail, vkType, vkMap, vkSet:
    return val

  # --- Mutable types: return a copy so mutation doesn't affect the AST ---
  of vkString:
    return ktgString(val.strVal, val.line)

  of vkBlock:
    var copy: seq[KtgValue] = @[]
    for v in val.blockVals: copy.add(v)
    return ktgBlock(copy, val.line)

  # --- Paren: evaluate contents, return last ---
  of vkParen:
    return eval.evalBlock(val.parenVals, ctx)

  # --- Context/Object: return self ---
  of vkContext, vkObject:
    return val

  # --- Function/Native: return self (encountered as value, not via word) ---
  of vkFunction, vkNative:
    return val

  # --- Operator: shouldn't appear bare ---
  of vkOp:
    raise KtgError(kind: "type", msg: "unexpected operator: " & val.opSymbol, data: nil)

  # --- Word ---
  of vkWord:
    case val.wordKind

    of wkWord:
      # check for path: word/segment/segment
      if val.wordName.contains('/'):
        let (head, segments) = parsePath(val.wordName)

        # check if head is a dialect (e.g. loop/collect, loop/fold)
        let pathDialect = eval.findDialect(head)
        if pathDialect != nil and pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos]
          pos += 1
          return pathDialect.interpret(blk.blockVals, eval, ctx, segments)

        let headVal = ctx.get(head)

        # if head is a native, treat segments as refinements
        if headVal.kind == vkNative:
          eval.currentRefinements = segments
          try:
            return eval.callCallable(headVal, vals, pos, ctx)
          finally:
            eval.currentRefinements = @[]

        # if head is a function, treat segments as refinements
        if headVal.kind == vkFunction:
          eval.currentRefinements = segments
          try:
            return eval.callCallable(headVal, vals, pos, ctx)
          finally:
            eval.currentRefinements = @[]

        # Navigate segments one at a time, stopping at callable values
        # to treat remaining segments as refinements (e.g., module/func/refinement)
        var parent = headVal
        var current = headVal
        var segIdx = 0
        while segIdx < segments.len:
          let seg = segments[segIdx]
          let next = eval.navigatePath(current, @[seg], ctx, val.wordName)
          # If resolved is callable and there are more segments, treat as refinements
          if isCallable(next) and segIdx + 1 < segments.len:
            eval.currentRefinements = segments[segIdx + 1 .. ^1]
            try:
              return eval.callCallable(next, vals, pos, ctx, current)
            finally:
              eval.currentRefinements = @[]
          parent = current
          current = next
          segIdx += 1
        # Final value: if callable, call it (self = parent object, not root)
        if isCallable(current):
          return eval.callCallable(current, vals, pos, ctx, parent)
        return current

      # check if it's a dialect first (before word lookup)
      let dialect = eval.findDialect(val.wordName)
      if dialect != nil and pos < vals.len and vals[pos].kind == vkBlock:
        let blk = vals[pos]
        pos += 1
        return dialect.interpret(blk.blockVals, eval, ctx)

      let bound = ctx.get(val.wordName)

      # callable: call it
      if isCallable(bound):
        var callResult = eval.callCallable(bound, vals, pos, ctx)
        # Macro auto-eval: if this is a macro and returned a block, evaluate it
        if val.wordName in eval.macros and callResult.kind == vkBlock:
          callResult = eval.evalBlock(callResult.blockVals, ctx)
        return callResult

      return bound

    of wkSetWord:
      # evaluate RHS with infix
      var rhs = eval.evalNext(vals, pos, ctx)
      eval.applyInfix(rhs, vals, pos, ctx)

      # Protect self from rebinding (only in the scope where self is defined)
      if val.wordName == "self" and "self" in ctx.entries:
        raise KtgError(kind: "self",
          msg: "cannot rebind self",
          data: nil)

      # Phantom types: `name!: @type ...` registers the rule in typeEnv and
      # does NOT bind the name as a runtime value. `name!` tokens lex as
      # vkType literals, so `is? name! v` picks up the rule via typeEnv.
      if rhs.kind == vkType and rhs.customType != nil and
         val.wordName.endsWith("!") and not val.wordName.contains('/'):
        eval.typeEnv[val.wordName] = rhs.customType
        return rhs

      # set-path: word/field/field: value
      if val.wordName.contains('/'):
        let (head, segments) = parsePath(val.wordName)
        if head == "self":
          # Prevent rebinding self itself
          if segments.len == 0:
            raise KtgError(kind: "self",
              msg: "cannot rebind self",
              data: nil)
        let headVal = ctx.get(head)
        # Navigate to the parent of the last segment
        var current = headVal
        for i in 0 ..< segments.len - 1:
          let seg = segments[i]
          try:
            # Dynamic get-word segment in set-path
            if seg.startsWith(":"):
              let varName = seg[1..^1]
              let idx = ctx.get(varName)
              if current.kind == vkBlock:
                if idx.kind == vkInteger:
                  let j = int(idx.intVal)
                  if j >= 1 and j <= current.blockVals.len:
                    current = current.blockVals[j - 1]
                  else:
                    raise KtgError(kind: "range",
                      msg: "index " & $j & " out of range", data: idx)
                else:
                  raise KtgError(kind: "type",
                    msg: "block index must be integer!", data: idx)
              elif current.kind == vkContext:
                current = current.ctx.get($idx)
              elif current.kind == vkMap:
                let key = $idx
                if key in current.mapEntries:
                  current = current.mapEntries[key]
                else:
                  raise KtgError(kind: "undefined", msg: key & " not found in map", data: nil)
              else:
                raise KtgError(kind: "type",
                  msg: "cannot navigate path on " & typeName(current), data: current)
            elif current.kind == vkContext:
              current = current.ctx.get(seg)
            elif current.kind == vkMap:
              if seg in current.mapEntries:
                current = current.mapEntries[seg]
              else:
                raise KtgError(kind: "undefined", msg: seg & " not found in map", data: nil)
            elif current.kind == vkObject:
              current = current.obj.get(seg)
            else:
              raise KtgError(kind: "type",
                msg: "cannot navigate path on " & typeName(current),
                data: current)
          except KtgError as e:
            if e.path.len == 0:
              e.path = val.wordName
              e.pathSeg = seg
            raise
        # Set on the final target
        let lastSeg = segments[^1]
        try:
          # Dynamic get-word as final segment
          if lastSeg.startsWith(":"):
            let varName = lastSeg[1..^1]
            let idx = ctx.get(varName)
            if current.kind == vkBlock:
              if idx.kind == vkInteger:
                let j = int(idx.intVal)
                if j >= 1 and j <= current.blockVals.len:
                  current.blockVals[j - 1] = rhs
                else:
                  raise KtgError(kind: "range",
                    msg: "index " & $j & " out of range", data: idx)
              else:
                raise KtgError(kind: "type",
                  msg: "block index must be integer!", data: idx)
            elif current.kind == vkContext:
              let dynKey = $idx
              if current.ctx.fieldSpecs.len > 0:
                for fs in current.ctx.fieldSpecs:
                  if fs.name == dynKey and fs.typeName != "":
                    let actual = typeName(rhs)
                    if not eval.typeMatches(actual, fs.typeName, rhs, ctx):
                      raise KtgError(kind: "type",
                        msg: "field '" & dynKey & "' expects " & fs.typeName & ", got " & actual,
                        data: rhs, line: val.line)
                    break
              current.ctx.set(dynKey, rhs)
            elif current.kind == vkMap:
              current.mapEntries[$idx] = rhs
            elif current.kind == vkObject:
              raise KtgError(kind: "frozen",
                msg: "cannot mutate object! directly; use `make Type [field: value]` to stamp a mutable context from the template",
                data: nil)
            else:
              raise KtgError(kind: "type",
                msg: "cannot set on " & typeName(current), data: current)
          elif current.kind == vkContext:
            if current.ctx.fieldSpecs.len > 0:
              for fs in current.ctx.fieldSpecs:
                if fs.name == lastSeg and fs.typeName != "":
                  let actual = typeName(rhs)
                  if not eval.typeMatches(actual, fs.typeName, rhs, ctx):
                    raise KtgError(kind: "type",
                      msg: "field '" & lastSeg & "' expects " & fs.typeName & ", got " & actual,
                      data: rhs, line: val.line)
                  break
            current.ctx.set(lastSeg, rhs)
          elif current.kind == vkMap:
            current.mapEntries[lastSeg] = rhs
          elif current.kind == vkObject:
            raise KtgError(kind: "frozen",
              msg: "cannot mutate object! directly; use `make Type [field: value]` to stamp a mutable context from the template",
              data: nil)
          elif current.kind in {vkPair, vkMoney, vkTuple, vkDate, vkTime}:
            ## Value types are immutable; set-path on a component rebuilds the
            ## whole value and writes it back to whatever holds it.
            let newVal = buildValueTypeRebind(current, lastSeg, rhs, val.line)
            if segments.len == 1:
              ctx.set(head, newVal)
            else:
              # Re-navigate head + segments[0..^3] to find the container holding
              # the value, then write newVal back at segments[^2].
              var holder = ctx.get(head)
              for i in 0 ..< segments.len - 2:
                let seg = segments[i]
                if holder.kind == vkContext: holder = holder.ctx.get(seg)
                elif holder.kind == vkMap: holder = holder.mapEntries[seg]
                elif holder.kind == vkObject: holder = holder.obj.get(seg)
                else:
                  raise KtgError(kind: "type",
                    msg: "cannot navigate path on " & typeName(holder), data: holder)
              let pKey = segments[^2]
              if holder.kind == vkContext:
                holder.ctx.set(pKey, newVal)
              elif holder.kind == vkMap:
                holder.mapEntries[pKey] = newVal
              elif holder.kind == vkObject:
                raise KtgError(kind: "frozen",
                  msg: "cannot mutate object! directly; use `make Type [field: value]` to stamp a mutable context from the template",
                data: nil)
              else:
                raise KtgError(kind: "type",
                  msg: "cannot set field on " & typeName(holder), data: holder)
          else:
            raise KtgError(kind: "type",
              msg: "cannot set field on " & typeName(current),
            data: current)
        except KtgError as e:
          if e.path.len == 0:
            e.path = val.wordName
            e.pathSeg = lastSeg
          raise
        return rhs

      # Auto-generation for object! assignment
      if rhs.kind == vkObject:
        let name = val.wordName
        let lowerName = toKebabCase(name)
        let customType = lowerName & "!"

        # Store the object name on the object
        rhs.obj.name = name

        # Register the type name
        if not ctx.has(customType):
          ctx.set(customType, ktgType(customType))

        # Register type predicate function: checks if value has all fields
        let predicateName = lowerName & "?"
        if not ctx.has(predicateName):
          let specs = rhs.obj.fieldSpecs
          ctx.set(predicateName, KtgValue(kind: vkNative,
            nativeFn: KtgNative(name: predicateName, arity: 1, fn: proc(
                args: seq[KtgValue], ep: pointer): KtgValue =
              let val = args[0]
              if val.kind != vkContext:
                return ktgLogic(false)
              for fs in specs:
                if fs.name notin val.ctx.entries:
                  return ktgLogic(false)
              ktgLogic(true)
            ),
            line: 0))

      # write-through: update existing binding, or create local if new
      ctx.setThrough(val.wordName, rhs)
      return rhs

    of wkGetWord:
      # return value without calling
      return ctx.get(val.wordName)

    of wkLitWord:
      # return the word as a symbol
      return val

    of wkMetaWord:
      # @type/guard — function constructor that flags the resulting fn as
      # eligible for use inside @type where-guard bodies. Two-block form
      # parallel to `function [params] [body]`. Compiler validates that
      # the body's reachable calls all resolve to compileable natives or
      # other @type/guard fns.
      if val.wordName == "type/guard":
        let paramsArg = eval.evalNext(vals, pos, ctx)
        let bodyArg = eval.evalNext(vals, pos, ctx)
        if paramsArg.kind != vkBlock or bodyArg.kind != vkBlock:
          raise KtgError(kind: "type",
            msg: "@type/guard expects [params] [body]", data: nil)
        let spec = parseFuncSpec(paramsArg.blockVals)
        let fn = KtgFunc(
          params: spec.params,
          refinements: spec.refinements,
          returnType: spec.returnType,
          body: bodyArg.blockVals,
          closure: ctx,
          isGuard: true
        )
        return KtgValue(kind: vkFunction, fn: fn, line: val.line)

      # @type — custom type creation
      if val.wordName == "type" or val.wordName.startsWith("type/"):
        let ruleBlock = eval.evalNext(vals, pos, ctx)
        if ruleBlock.kind != vkBlock:
          raise KtgError(kind: "type", msg: "@type expects a block argument", data: nil)

        var guardBlock: seq[KtgValue] = @[]
        var isEnum = false

        # Check for refinements in the meta-word name
        if val.wordName == "type/where":
          # consume the guard block
          let guardArg = eval.evalNext(vals, pos, ctx)
          if guardArg.kind != vkBlock:
            raise KtgError(kind: "type", msg: "@type/where expects a guard block", data: nil)
          guardBlock = guardArg.blockVals
        elif val.wordName == "type/enum":
          isEnum = true

        # Determine if this is a structural type: ['name [string!] 'age [integer!]]
        var isStruct = false
        let ruleVals = ruleBlock.blockVals
        if ruleVals.len >= 2 and not isEnum:
          # structural if first element is a lit-word and second is a block
          if ruleVals[0].kind == vkWord and ruleVals[0].wordKind == wkLitWord and
             ruleVals.len >= 2 and ruleVals[1].kind == vkBlock:
            # Check it's not a union (which has | operators)
            var hasBar = false
            for rv in ruleVals:
              if rv.kind == vkWord and rv.wordKind == wkWord and rv.wordName == "|":
                hasBar = true
                break
              if rv.kind == vkOp and rv.opSymbol == "|":
                hasBar = true
                break
            if not hasBar:
              isStruct = true

        let ct = CustomType(
          rule: ruleVals,
          guard: guardBlock,
          isEnum: isEnum,
          isStruct: isStruct
        )

        # Return a type value with the custom type attached
        let typeVal = ktgType("custom-type!")
        typeVal.customType = ct
        return typeVal

      # @const value — annotate following expression as a constant binding.
      # Canonical form is `name: @const value` (parallel to @type, @type/guard,
      # @type/where, @type/enum, @compose, @template, @parse — every meta-word
      # follows the set-word).
      if val.wordName == "const":
        if pos < vals.len:
          var rhs = eval.evalNext(vals, pos, ctx)
          eval.applyInfix(rhs, vals, pos, ctx)
          return rhs
        return val

      # #compose — block composition with paren interpolation
      # Default: splice block results. /only: insert as single element.
      # /deep: recurse into nested blocks.
      if val.wordName == "compose" or val.wordName.startsWith("compose/"):
        let parts = val.wordName.split('/')
        let deep = "deep" in parts
        let only = "only" in parts
        let arg = eval.evalNext(vals, pos, ctx)
        if arg.kind != vkBlock:
          raise KtgError(kind: "type", msg: "@compose expects a block", data: nil)
        proc composeBlock(eval: Evaluator, blk: seq[KtgValue], ctx: KtgContext,
                          deep: bool, only: bool): seq[KtgValue] =
          var results: seq[KtgValue] = @[]
          for v in blk:
            if v.kind == vkParen:
              let val = eval.evalBlock(v.parenVals, ctx)
              if val.kind == vkBlock and not only:
                # Splice block contents
                for item in val.blockVals:
                  results.add(item)
              else:
                results.add(val)
            elif deep and v.kind == vkBlock:
              results.add(ktgBlock(composeBlock(eval, v.blockVals, ctx, deep, only)))
            else:
              results.add(v)
          results
        return ktgBlock(composeBlock(eval, arg.blockVals, ctx, deep, only))

      # @parse — parsing
      if val.wordName == "parse" or val.wordName.startsWith("parse/"):
        let input = eval.evalNext(vals, pos, ctx)
        let rules = eval.evalNext(vals, pos, ctx)
        return eval.parseFn(eval, input, rules, val.wordName == "parse/ok?")

      # lifecycle hooks — for now return self
      return val


proc evalBlock*(eval: Evaluator, vals: seq[KtgValue],
                ctx: KtgContext): KtgValue =
  # Check for @enter / @exit lifecycle hooks. Partitioning logic shared
  # with the Lua emitter via src/core/lifecycle.nim.
  let lc = partitionLifecycle(vals)
  if lc.hasHooks:
    # Run @enter hooks
    for blk in lc.enterBlocks:
      discard eval.evalBlock(blk, ctx)

    # Run body with finally for @exit
    try:
      result = ktgNone()
      var pos = 0
      while pos < lc.body.len:
        let startLine = lc.body[pos].line
        try:
          result = eval.evalNext(lc.body, pos, ctx)
          eval.applyInfix(result, lc.body, pos, ctx)
        except KtgError as e:
          discard e.attachLine(startLine)
          raise
    finally:
      for blk in lc.exitBlocks:
        discard eval.evalBlock(blk, ctx)
  else:
    result = ktgNone()
    var pos = 0
    while pos < vals.len:
      let startLine = vals[pos].line
      try:
        result = eval.evalNext(vals, pos, ctx)
        eval.applyInfix(result, vals, pos, ctx)
      except KtgError as e:
        discard e.attachLine(startLine)
        raise


proc matchesCustomTypeByName*(eval: Evaluator, value: KtgValue, typeName: string, ctx: KtgContext): bool
proc typeMatchesBuiltin*(actual, expected: string): bool

proc matchesCustomType*(eval: Evaluator, value: KtgValue, ct: CustomType, ctx: KtgContext): bool =
  ## Check if a value matches a custom type definition.
  if ct.isEnum:
    # Enum: rule contains ['north | 'south | 'east | 'west]
    # Value must be a lit-word matching one of the enum members
    # @type/enum forces CASE-SENSITIVE matching
    for rv in ct.rule:
      if rv.kind == vkWord and rv.wordKind == wkLitWord:
        if value.kind == vkWord and value.wordKind == wkLitWord and
           value.wordName == rv.wordName:  # exact case match
          return true
    return false

  if ct.isStruct:
    # Structural: ['name [string!] 'age [integer!]]
    # Value must be a context/block with matching fields
    var target: KtgContext = nil
    if value.kind == vkContext:
      target = value.ctx
    elif value.kind == vkBlock:
      # Treat block as flat key-value pairs: [name "Alice" age 25]
      if value.blockVals.len mod 2 != 0:
        raise KtgError(kind: "type",
          msg: "block used as key-value pairs must have even length",
          data: value)
      # Build a temporary context from it
      let tmpCtx = newContext()
      var i = 0
      while i < value.blockVals.len - 1:
        let k = value.blockVals[i]
        let v = value.blockVals[i + 1]
        if k.kind == vkWord and k.wordKind == wkWord:
          tmpCtx.set(k.wordName, v)
        i += 2
      target = tmpCtx
    else:
      return false

    # Walk rule pairs: 'fieldName [type!]
    var i = 0
    while i < ct.rule.len:
      if ct.rule[i].kind == vkWord and ct.rule[i].wordKind == wkLitWord:
        let fieldName = ct.rule[i].wordName
        if not target.has(fieldName):
          return false
        if i + 1 < ct.rule.len and ct.rule[i + 1].kind == vkBlock:
          let typeBlock = ct.rule[i + 1].blockVals
          if typeBlock.len > 0 and typeBlock[0].kind == vkType:
            let expectedType = typeBlock[0].typeName
            let fieldVal = target.get(fieldName)
            if typeName(fieldVal) != expectedType:
              # Also check if the expected type is itself a custom type
              if not eval.matchesCustomTypeByName(fieldVal, expectedType, ctx):
                return false
          i += 2
          continue
      i += 1
    return true

  # Non-enum lit-word matching: @type ['north | 'south | 'east | 'west]
  # Case-INSENSITIVE (REBOL style) — use @type/enum for case-sensitive
  var hasLitWords = false
  for rv in ct.rule:
    if rv.kind == vkWord and rv.wordKind == wkLitWord:
      hasLitWords = true
      break
  if hasLitWords:
    for rv in ct.rule:
      if rv.kind == vkWord and rv.wordKind == wkLitWord:
        if value.kind == vkWord and value.wordKind == wkLitWord and
           toLower(value.wordName) == toLower(rv.wordName):  # case-insensitive
          return true
    return false

  # Union type: [string! | none!] or [integer! | float!]
  # Split on | and check if value matches any
  var typeNames: seq[string] = @[]
  for rv in ct.rule:
    if rv.kind == vkType:
      typeNames.add(rv.typeName)

  if typeNames.len > 0:
    let actual = typeName(value)
    for tn in typeNames:
      if actual == tn:
        if ct.guard.len > 0:
          let guardCtx = ctx.child
          guardCtx.set("it", value)
          let guardResult = eval.evalBlock(ct.guard, guardCtx)
          if guardResult.kind != vkLogic:
            raise KtgError(kind: "type",
              msg: "where guard must return logic!, got " & typeName(guardResult),
              data: guardResult)
          return guardResult.boolVal
        return true
      if typeMatchesBuiltin(actual, tn):
        if ct.guard.len > 0:
          let guardCtx = ctx.child
          guardCtx.set("it", value)
          let guardResult = eval.evalBlock(ct.guard, guardCtx)
          if guardResult.kind != vkLogic:
            raise KtgError(kind: "type",
              msg: "where guard must return logic!, got " & typeName(guardResult),
              data: guardResult)
          return guardResult.boolVal
        return true
      if eval.matchesCustomTypeByName(value, tn, ctx):
        if ct.guard.len > 0:
          let guardCtx = ctx.child
          guardCtx.set("it", value)
          let guardResult = eval.evalBlock(ct.guard, guardCtx)
          if guardResult.kind != vkLogic:
            raise KtgError(kind: "type",
              msg: "where guard must return logic!, got " & typeName(guardResult),
              data: guardResult)
          return guardResult.boolVal
        return true
    return false

  # If no type names found in rule but we have a guard, check guard only
  if ct.guard.len > 0:
    let guardCtx = ctx.child
    guardCtx.set("it", value)
    let guardResult = eval.evalBlock(ct.guard, guardCtx)
    return isTruthy(guardResult)

  false

proc typeMatchesBuiltin*(actual, expected: string): bool =
  ## Check built-in type aliases only (no custom type lookup).
  if expected == actual: return true
  if expected == "any-type!": return true
  case expected
  of "number!": actual in ["integer!", "float!"]
  of "any-word!": actual in ["word!", "set-word!", "get-word!", "lit-word!", "meta-word!"]
  of "scalar!": actual in ["integer!", "float!", "money!", "date!", "time!", "pair!", "tuple!"]
  of "any-block!": actual in ["block!", "paren!", "path!"]
  else: false

proc matchesCustomTypeByName*(eval: Evaluator, value: KtgValue, typeName: string, ctx: KtgContext): bool =
  ## Phantom type lookup. typeEnv is authoritative. Legacy fallbacks handle
  ## object auto-gen (predicate function) and pre-phantom code that still
  ## stores a customType as a value.
  if typeName in eval.typeEnv:
    return eval.matchesCustomType(value, eval.typeEnv[typeName], ctx)
  if ctx.has(typeName):
    let typeVal = ctx.get(typeName)
    if typeVal.customType != nil:
      return eval.matchesCustomType(value, typeVal.customType, ctx)
  # Fallback: try the predicate function (e.g., card! -> card?)
  let baseName = if typeName.endsWith("!"): typeName[0 .. ^2] else: typeName
  let predicateName = baseName & "?"
  if ctx.has(predicateName):
    let predFn = ctx.get(predicateName)
    if predFn.kind in {vkNative, vkFunction}:
      var args = @[value]
      var pos = 0
      let res = eval.callCallable(predFn, args, pos, ctx)
      return res.kind == vkLogic and res.boolVal
  false

proc typeMatches*(eval: Evaluator, actual, expected: string, value: KtgValue, ctx: KtgContext): bool =
  ## Extended type matching that handles custom types.
  if expected == actual: return true
  if expected == "any-type!": return true
  case expected
  of "number!": return actual in ["integer!", "float!"]
  of "any-word!": return actual in ["word!", "set-word!", "get-word!", "lit-word!", "meta-word!"]
  of "scalar!": return actual in ["integer!", "float!", "money!", "date!", "time!", "pair!", "tuple!"]
  of "any-block!": return actual in ["block!", "paren!", "path!"]
  else:
    # Check if this is a custom type
    return eval.matchesCustomTypeByName(value, expected, ctx)

proc callCallable*(eval: Evaluator, fn: KtgValue, vals: seq[KtgValue],
                   pos: var int, ctx: KtgContext, selfVal: KtgValue = nil): KtgValue =
  case fn.kind

  of vkNative:
    let native = fn.nativeFn
    # collect args
    var args: seq[KtgValue] = @[]
    for i in 0 ..< native.arity:
      if pos >= vals.len:
        raise KtgError(kind: "arity",
          msg: native.name & " expects " & $native.arity & " arguments",
          data: nil)
      var arg = eval.evalNext(vals, pos, ctx)
      eval.applyInfix(arg, vals, pos, ctx)
      args.add(arg)

    # Consume refinement params for natives (like functions do)
    for refSpec in native.refinements:
      if refSpec.name in eval.currentRefinements:
        for rp in refSpec.params:
          if pos >= vals.len:
            raise KtgError(kind: "arity",
              msg: "refinement /" & refSpec.name & " expects argument " & rp.name,
              data: nil)
          var rarg = eval.evalNext(vals, pos, ctx)
          eval.applyInfix(rarg, vals, pos, ctx)
          args.add(rarg)

    if eval.callStack.len > 512:
      raise KtgError(kind: "stack", msg: "stack overflow: recursion depth exceeded 512", data: nil)
    eval.callStack.add(StackFrame(name: native.name, file: "", line: 0))
    let savedCtx = eval.currentCtx
    eval.currentCtx = ctx
    when defined(js):
      currentEvaluator = eval
    try:
      result = native.fn(args, cast[pointer](eval))
    finally:
      eval.currentCtx = savedCtx
      discard eval.callStack.pop
    return result

  of vkFunction:
    let f = fn.fn
    # collect args
    var args: seq[KtgValue] = @[]
    for i in 0 ..< f.params.len:
      if pos >= vals.len:
        raise KtgError(kind: "arity",
          msg: "function expects " & $f.params.len & " arguments",
          data: nil)
      var arg = eval.evalNext(vals, pos, ctx)
      eval.applyInfix(arg, vals, pos, ctx)
      args.add(arg)

    # create function scope
    let funcCtx = f.closure.child
    for i, param in f.params:
      # type check
      if param.typeName != "" and param.typeName != "any-type!":
        let actual = typeName(args[i])
        if not eval.typeMatches(actual, param.typeName, args[i], ctx):
          raise KtgError(kind: "type",
            msg: param.name & " expects " & param.typeName & ", got " & actual,
            data: args[i])
        # Typed block check: [block! integer!] means all elements must be integer!
        if param.elementType != "" and args[i].kind == vkBlock:
          for elem in args[i].blockVals:
            let elemActual = typeName(elem)
            if not eval.typeMatches(elemActual, param.elementType, elem, ctx):
              raise KtgError(kind: "type",
                msg: param.name & " expects block of " & param.elementType & ", got element of " & elemActual,
                data: elem)
      funcCtx.set(param.name, args[i])

    # bind self if provided
    if selfVal != nil:
      funcCtx.set("self", selfVal)

    # bind refinements
    for refSpec in f.refinements:
      if refSpec.name in eval.currentRefinements:
        funcCtx.set(refSpec.name, ktgLogic(true))
        # consume extra args for refinement parameters
        for rp in refSpec.params:
          if pos >= vals.len:
            raise KtgError(kind: "arity",
              msg: "refinement /" & refSpec.name & " expects argument " & rp.name,
              data: nil)
          var rarg = eval.evalNext(vals, pos, ctx)
          eval.applyInfix(rarg, vals, pos, ctx)
          # type check refinement param
          if rp.typeName != "" and rp.typeName != "any-type!":
            let actual = typeName(rarg)
            if not eval.typeMatches(actual, rp.typeName, rarg, ctx):
              raise KtgError(kind: "type",
                msg: rp.name & " expects " & rp.typeName & ", got " & actual,
                data: rarg)
          funcCtx.set(rp.name, rarg)
      else:
        funcCtx.set(refSpec.name, ktgLogic(false))
        for rp in refSpec.params:
          funcCtx.set(rp.name, ktgNone())

    if eval.callStack.len > 512:
      raise KtgError(kind: "stack", msg: "stack overflow: recursion depth exceeded 512", data: nil)
    eval.callStack.add(StackFrame(name: "function", file: "", line: 0))
    try:
      result = eval.evalBlock(f.body, funcCtx)
    except ReturnSignal as r:
      result = r.value
    finally:
      discard eval.callStack.pop

    # return type check
    if f.returnType != "" and f.returnType != "any-type!":
      let actual = typeName(result)
      if not eval.typeMatches(actual, f.returnType, result, ctx):
        raise KtgError(kind: "type",
          msg: "return type mismatch: expected " & f.returnType & ", got " & actual,
          data: result)

    return result

  else:
    raise KtgError(kind: "type",
      msg: "not callable: " & typeName(fn), data: fn)


# --- Preprocessing (#preprocess) ---

proc preprocess*(eval: Evaluator, ast: seq[KtgValue],
                 forCompilation: bool = false,
                 target: string = ""): seq[KtgValue] =
  ## Walk the AST looking for:
  ##   @preprocess [block]  - evaluate block, splice emitted values
  ##   @inline [expr]       - evaluate expr, splice result
  ##   @template name: ...  - register template (expanded at call site)
  ##   template calls       - expand and splice
  ## When forCompilation=true, system/platform is set to 'lua.

  # Quick scan: anything to do?
  var hasWork = false
  for v in ast:
    if v.kind == vkWord and v.wordKind == wkMetaWord and
       v.wordName in ["preprocess", "inline", "game",
                      "template", "template/deep", "template/only"]:
      hasWork = true
      break
    if forCompilation and v.kind == vkWord and v.wordKind == wkWord and
       v.wordName in ["import", "import/using"]:
      hasWork = true
      break
  # Also check for macro calls from prior passes
  if not hasWork and eval.macros.len > 0:
    for v in ast:
      if v.kind == vkWord and v.wordKind == wkWord and v.wordName in eval.macros:
        hasWork = true
        break
  if not hasWork:
    return ast

  # Set platform for preprocessing
  if forCompilation:
    let sys = eval.global.get("system")
    if sys.kind == vkContext:
      sys.ctx.set("platform", ktgWord("lua", wkLitWord))

  result = @[]
  var i = 0
  while i < ast.len:
    # @inline [expr]
    if ast[i].kind == vkWord and ast[i].wordKind == wkMetaWord and
       ast[i].wordName == "inline" and i + 1 < ast.len and
       ast[i + 1].kind == vkBlock:
      let value = eval.evalBlock(ast[i + 1].blockVals, eval.global)
      if value != nil and value.kind != vkNone:
        if value.kind == vkBlock:
          for v in value.blockVals:
            result.add(v)
        else:
          result.add(value)
      i += 2

    # @preprocess [block]
    elif ast[i].kind == vkWord and ast[i].wordKind == wkMetaWord and
       ast[i].wordName == "preprocess" and i + 1 < ast.len and
       ast[i + 1].kind == vkBlock:
      let ppCtx = eval.global.child
      var emitted: seq[KtgValue] = @[]

      ppCtx.set("emit", KtgValue(kind: vkNative,
        nativeFn: KtgNative(name: "emit", arity: 1, fn: proc(
            args: seq[KtgValue], ep: pointer): KtgValue =
          if args[0].kind == vkBlock:
            for v in args[0].blockVals:
              emitted.add(v)
          else:
            emitted.add(args[0])
          ktgNone()
        ),
        line: 0))

      discard eval.evalBlock(ast[i + 1].blockVals, ppCtx)

      for v in emitted:
        result.add(v)

      i += 2

    # @template name: [spec] [body]                — declarative compile-time
    # @template/deep name: [spec] [body]            — @compose/deep body
    # @template/only name: [spec] [body]            — @compose/only body
    elif ast[i].kind == vkWord and ast[i].wordKind == wkMetaWord and
       (ast[i].wordName == "template" or
        ast[i].wordName == "template/deep" or
        ast[i].wordName == "template/only") and i + 3 < ast.len and
       ast[i + 1].kind == vkWord and ast[i + 1].wordKind == wkSetWord and
       ast[i + 2].kind == vkBlock and ast[i + 3].kind == vkBlock:
      let compName = ast[i + 1].wordName
      let specBlock = ast[i + 2]
      let userBody = ast[i + 3]
      let composeName =
        case ast[i].wordName
        of "template/deep": "compose/deep"
        of "template/only": "compose/only"
        else: "compose"
      ## Synthesize `function [<spec>] [@compose[/mode] [<body>]]`.
      let composedBody = ktgBlock(@[
        ktgWord(composeName, wkMetaWord),
        userBody,
      ])
      var fnAst = @[
        ktgWord("function", wkWord),
        specBlock,
        composedBody,
      ]
      var defPos = 0
      let fnVal = eval.evalNext(fnAst, defPos, eval.global)
      eval.macros.incl(compName)
      eval.global.set(compName, fnVal)
      i += 4

    # Macro call - expand
    elif ast[i].kind == vkWord and ast[i].wordKind == wkWord and
       ast[i].wordName in eval.macros:
      let macroName = ast[i].wordName
      let macroFn = eval.global.get(macroName)
      # Consume the macro's arguments and call it
      var callPos = i + 1
      let expanded = eval.callCallable(macroFn, ast, callPos, eval.global)
      # Splice the result block into the output
      if expanded.kind == vkBlock:
        for v in expanded.blockVals:
          result.add(v)
      else:
        result.add(expanded)
      i = callPos

    # @game [block] - preprocess-time dialect expansion
    elif ast[i].kind == vkWord and ast[i].wordKind == wkMetaWord and
       ast[i].wordName == "game" and i + 1 < ast.len and
       ast[i + 1].kind == vkBlock:
      ## Hand the dialect a template-expansion callback so that user-defined
      ## @template names can be called inside entity bodies. Produces
      ## dialect vocabulary (field/update/draw/...) via splicing.
      let expander: game_dialect.MacroExpander = proc(body: seq[KtgValue]): seq[KtgValue] =
        var i2 = 0
        while i2 < body.len:
          if body[i2].kind == vkWord and body[i2].wordKind == wkWord and
             body[i2].wordName in eval.macros:
            let mFn = eval.global.get(body[i2].wordName)
            var cp = i2 + 1
            let mExpanded = eval.callCallable(mFn, body, cp, eval.global)
            if mExpanded.kind == vkBlock:
              for v in mExpanded.blockVals:
                result.add(v)
            else:
              result.add(mExpanded)
            i2 = cp
          else:
            result.add(body[i2])
            i2 += 1
      let expanded = game_dialect.expand(ast[i + 1].blockVals, target, expander)
      for v in expanded:
        result.add(v)
      i += 2

    # import 'module / import/using 'module [symbols] - in compilation mode
    # the import statement is preserved verbatim; the emitter detects it
    # during prescan and routes the requested functions into prelude.lua
    # (where they live as globals) rather than splicing them inline into
    # the user's source.lua. Validate the module name here so unknown
    # imports fail at preprocess time, not at emit time.
    elif forCompilation and ast[i].kind == vkWord and ast[i].wordKind == wkWord and
       ast[i].wordName in ["import", "import/using"] and i + 1 < ast.len and
       ast[i + 1].kind == vkWord and ast[i + 1].wordKind == wkLitWord:
      let moduleName = ast[i + 1].wordName
      if moduleName notin stdlibModules:
        raise KtgError(kind: "import",
          msg: "unknown module: " & moduleName, data: nil)
      result.add(ast[i])
      result.add(ast[i + 1])
      i += 2
      if ast[i - 2].wordName == "import/using" and i < ast.len and
         ast[i].kind == vkBlock:
        result.add(ast[i])
        i += 1

    else:
      result.add(ast[i])
      i += 1

  # Restore platform
  if forCompilation:
    let sys = eval.global.get("system")
    if sys.kind == vkContext:
      sys.ctx.set("platform", ktgWord("script", wkLitWord))


# --- Convenience ---

proc evalString*(eval: Evaluator, src: string): KtgValue =
  let ast = parseSource(src)
  let processed = eval.preprocess(ast)
  eval.evalBlock(processed, eval.global)

proc getOutput*(eval: Evaluator): string =
  eval.output.join("\n")

proc clearOutput*(eval: Evaluator) =
  eval.output = @[]
