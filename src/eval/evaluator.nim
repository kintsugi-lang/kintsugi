import std/[strutils, tables, math, sets]
import ../core/[types, equality]
import ../parse/parser
import dialect
import ../dialects/game_dialect

export Evaluator

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
    moduleLoading: initHashSet[string]()
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
                   ctx: KtgContext): KtgValue =
  var current = head
  for seg in segments:
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
        raise KtgError(kind: "undefined", msg: seg & " not found on pair (use /x or /y)", data: nil)
    elif current.kind == vkTuple:
      # tuple/1, tuple/2, tuple/3 for indexed access
      try:
        let idx = parseInt(seg)
        if idx >= 1 and idx <= current.tupleVals.len:
          current = ktgInt(int64(current.tupleVals[idx - 1]))
        else:
          raise KtgError(kind: "range", msg: "tuple index " & seg & " out of range", data: nil)
      except ValueError:
        raise KtgError(kind: "undefined", msg: seg & " not found on tuple (use /1, /2, etc.)", data: nil)
    else:
      raise KtgError(kind: "type",
        msg: "cannot navigate path on " & typeName(current), data: nil)
  current


proc parsePath*(word: string): (string, seq[string]) =
  ## Split "obj/field/sub" into ("obj", @["field", "sub"])
  let parts = word.split('/')
  (parts[0], parts[1..^1])


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
          let next = eval.navigatePath(current, @[seg], ctx)
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
        # Set on the final target
        let lastSeg = segments[^1]
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
            current.ctx.set($idx, rhs)
          elif current.kind == vkMap:
            current.mapEntries[$idx] = rhs
          elif current.kind == vkObject:
            raise KtgError(kind: "frozen",
              msg: "cannot mutate frozen object", data: nil)
          else:
            raise KtgError(kind: "type",
              msg: "cannot set on " & typeName(current), data: current)
        elif current.kind == vkContext:
          current.ctx.set(lastSeg, rhs)
        elif current.kind == vkMap:
          current.mapEntries[lastSeg] = rhs
        elif current.kind == vkObject:
          raise KtgError(kind: "frozen",
            msg: "cannot mutate frozen object", data: nil)
        elif current.kind == vkPair and (lastSeg == "x" or lastSeg == "y"):
          let v =
            if rhs.kind == vkInteger: float64(rhs.intVal)
            elif rhs.kind == vkFloat: rhs.floatVal
            else:
              raise KtgError(kind: "type",
                msg: "pair! field must be integer! or float!, got " & typeName(rhs),
                data: rhs)
          let newPair =
            if lastSeg == "x": ktgPair(v, current.py, val.line)
            else: ktgPair(current.px, v, val.line)
          if segments.len == 1:
            ctx.set(head, newPair)
          else:
            # Re-navigate head + segments[0..^3] to find the container holding
            # the pair, then write newPair back at segments[^2].
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
              holder.ctx.set(pKey, newPair)
            elif holder.kind == vkMap:
              holder.mapEntries[pKey] = newPair
            elif holder.kind == vkObject:
              raise KtgError(kind: "frozen",
                msg: "cannot mutate frozen object", data: nil)
            else:
              raise KtgError(kind: "type",
                msg: "cannot set pair field on " & typeName(holder), data: holder)
        elif current.kind == vkPair:
          raise KtgError(kind: "undefined",
            msg: lastSeg & " not found on pair! (use /x or /y)", data: nil)
        else:
          raise KtgError(kind: "type",
            msg: "cannot set field on " & typeName(current),
            data: current)
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

      # @const x: value — compile-time annotation, interpreter treats as normal assignment
      if val.wordName == "const":
        if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkSetWord:
          let setWord = vals[pos]
          pos += 1
          var rhs = eval.evalNext(vals, pos, ctx)
          eval.applyInfix(rhs, vals, pos, ctx)
          ctx.set(setWord.wordName, rhs)
          return rhs
        return val

      # @macro — tag the next function definition as a macro
      if val.wordName == "macro":
        if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkSetWord:
          let setWord = vals[pos]
          pos += 1
          var rhs = eval.evalNext(vals, pos, ctx)
          eval.applyInfix(rhs, vals, pos, ctx)
          eval.macros.incl(setWord.wordName)
          ctx.set(setWord.wordName, rhs)
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
  # Check for @enter / @exit lifecycle hooks
  var hasHooks = false
  for v in vals:
    if v.kind == vkWord and v.wordKind == wkMetaWord and
       v.wordName in ["enter", "exit"]:
      hasHooks = true
      break

  if hasHooks:
    var enterBlocks: seq[seq[KtgValue]] = @[]
    var exitBlocks: seq[seq[KtgValue]] = @[]
    var bodyVals: seq[KtgValue] = @[]
    var i = 0
    while i < vals.len:
      if vals[i].kind == vkWord and vals[i].wordKind == wkMetaWord:
        if vals[i].wordName == "enter" and i + 1 < vals.len and
           vals[i + 1].kind == vkBlock:
          enterBlocks.add(vals[i + 1].blockVals)
          i += 2
          continue
        if vals[i].wordName == "exit" and i + 1 < vals.len and
           vals[i + 1].kind == vkBlock:
          exitBlocks.add(vals[i + 1].blockVals)
          i += 2
          continue
      bodyVals.add(vals[i])
      i += 1

    # Run @enter hooks
    for blk in enterBlocks:
      discard eval.evalBlock(blk, ctx)

    # Run body with finally for @exit
    try:
      result = ktgNone()
      var pos = 0
      while pos < bodyVals.len:
        result = eval.evalNext(bodyVals, pos, ctx)
        eval.applyInfix(result, bodyVals, pos, ctx)
    finally:
      for blk in exitBlocks:
        discard eval.evalBlock(blk, ctx)
  else:
    result = ktgNone()
    var pos = 0
    while pos < vals.len:
      result = eval.evalNext(vals, pos, ctx)
      eval.applyInfix(result, vals, pos, ctx)


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
        # Base type matches, now check guard
        if ct.guard.len > 0:
          let guardCtx = ctx.child
          guardCtx.set("it", value)
          let guardResult = eval.evalBlock(ct.guard, guardCtx)
          return isTruthy(guardResult)
        return true
      # Check if tn is a built-in union type
      if typeMatchesBuiltin(actual, tn):
        if ct.guard.len > 0:
          let guardCtx = ctx.child
          guardCtx.set("it", value)
          let guardResult = eval.evalBlock(ct.guard, guardCtx)
          return isTruthy(guardResult)
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
  ## Look up a custom type by name in context and check if value matches.
  # Try to find the type with a customType object
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
  ##   @macro name: fn      - register macro (expanded at call site)
  ##   macro calls          - expand and splice
  ## When forCompilation=true, system/platform is set to 'lua.

  # Quick scan: anything to do?
  var hasWork = false
  for v in ast:
    if v.kind == vkWord and v.wordKind == wkMetaWord and
       v.wordName in ["preprocess", "inline", "macro", "game"]:
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

    # @macro name: function [spec] [body] - register and skip
    elif ast[i].kind == vkWord and ast[i].wordKind == wkMetaWord and
       ast[i].wordName == "macro" and i + 1 < ast.len and
       ast[i + 1].kind == vkWord and ast[i + 1].wordKind == wkSetWord:
      let macroName = ast[i + 1].wordName
      # Evaluate the macro definition in global scope
      var defPos = i + 2
      let macroVal = eval.evalNext(ast, defPos, eval.global)
      eval.macros.incl(macroName)
      eval.global.set(macroName, macroVal)
      i = defPos

    # @component name: [spec] [body] - sugar for @macro name: function [spec] [@compose [body]]
    elif ast[i].kind == vkWord and ast[i].wordKind == wkMetaWord and
       ast[i].wordName == "component" and i + 3 < ast.len and
       ast[i + 1].kind == vkWord and ast[i + 1].wordKind == wkSetWord and
       ast[i + 2].kind == vkBlock and ast[i + 3].kind == vkBlock:
      let compName = ast[i + 1].wordName
      let specBlock = ast[i + 2]
      let userBody = ast[i + 3]
      ## Synthesize `function [<spec>] [@compose [<body>]]`.
      let composedBody = ktgBlock(@[
        ktgWord("compose", wkMetaWord),
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
      ## Hand the dialect a macro-expansion callback so that user-defined
      ## @component macros can be called inside entity bodies. Produces
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
