import std/[strutils, tables, math, sets]
import ../core/[types, equality]
import ../parse/parser
import dialect

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

  # string concatenation via +
  if left.kind == vkString and right.kind == vkString and op == "+":
    return ktgString(left.strVal & right.strVal)

  # comparison ops
  case op
  of "=":  return ktgLogic(valuesEqual(left, right))
  of "==":
    const nonScalar = {vkBlock, vkParen, vkMap, vkSet, vkContext, vkPrototype,
                       vkFunction, vkNative, vkOp}
    if left.kind in nonScalar or right.kind in nonScalar:
      raise KtgError(kind: "type",
        msg: "== requires scalar types, got " & typeName(left) & " and " & typeName(right),
        data: nil)
    return ktgLogic(left.kind == right.kind and valuesEqual(left, right))
  of "<>": return ktgLogic(not valuesEqual(left, right))
  of "<":
    if left.kind in {vkInteger, vkFloat} and right.kind in {vkInteger, vkFloat}:
      let lf = if left.kind == vkInteger: float64(left.intVal) else: left.floatVal
      let rf = if right.kind == vkInteger: float64(right.intVal) else: right.floatVal
      return ktgLogic(lf < rf)
    if left.kind == vkString and right.kind == vkString:
      return ktgLogic(left.strVal < right.strVal)
    if left.kind == vkMoney and right.kind == vkMoney:
      return ktgLogic(left.cents < right.cents)
    if left.kind == vkDate and right.kind == vkDate:
      return ktgLogic(
        (left.year, left.month, left.day) < (right.year, right.month, right.day))
    if left.kind == vkTime and right.kind == vkTime:
      return ktgLogic(
        (left.hour, left.minute, left.second) < (right.hour, right.minute, right.second))
  of ">":
    if left.kind in {vkInteger, vkFloat} and right.kind in {vkInteger, vkFloat}:
      let lf = if left.kind == vkInteger: float64(left.intVal) else: left.floatVal
      let rf = if right.kind == vkInteger: float64(right.intVal) else: right.floatVal
      return ktgLogic(lf > rf)
    if left.kind == vkString and right.kind == vkString:
      return ktgLogic(left.strVal > right.strVal)
    if left.kind == vkMoney and right.kind == vkMoney:
      return ktgLogic(left.cents > right.cents)
    if left.kind == vkDate and right.kind == vkDate:
      return ktgLogic(
        (left.year, left.month, left.day) > (right.year, right.month, right.day))
    if left.kind == vkTime and right.kind == vkTime:
      return ktgLogic(
        (left.hour, left.minute, left.second) > (right.hour, right.minute, right.second))
  of "<=":
    if left.kind in {vkInteger, vkFloat} and right.kind in {vkInteger, vkFloat}:
      let lf = if left.kind == vkInteger: float64(left.intVal) else: left.floatVal
      let rf = if right.kind == vkInteger: float64(right.intVal) else: right.floatVal
      return ktgLogic(lf <= rf)
    if left.kind == vkString and right.kind == vkString:
      return ktgLogic(left.strVal <= right.strVal)
    if left.kind == vkMoney and right.kind == vkMoney:
      return ktgLogic(left.cents <= right.cents)
    if left.kind == vkDate and right.kind == vkDate:
      return ktgLogic(
        (left.year, left.month, left.day) <= (right.year, right.month, right.day))
    if left.kind == vkTime and right.kind == vkTime:
      return ktgLogic(
        (left.hour, left.minute, left.second) <= (right.hour, right.minute, right.second))
  of ">=":
    if left.kind in {vkInteger, vkFloat} and right.kind in {vkInteger, vkFloat}:
      let lf = if left.kind == vkInteger: float64(left.intVal) else: left.floatVal
      let rf = if right.kind == vkInteger: float64(right.intVal) else: right.floatVal
      return ktgLogic(lf >= rf)
    if left.kind == vkString and right.kind == vkString:
      return ktgLogic(left.strVal >= right.strVal)
    if left.kind == vkMoney and right.kind == vkMoney:
      return ktgLogic(left.cents >= right.cents)
    if left.kind == vkDate and right.kind == vkDate:
      return ktgLogic(
        (left.year, left.month, left.day) >= (right.year, right.month, right.day))
    if left.kind == vkTime and right.kind == vkTime:
      return ktgLogic(
        (left.hour, left.minute, left.second) >= (right.hour, right.minute, right.second))
  else: discard

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
      elif result.kind == vkPrototype:
        methodFn = result.proto.get(methodName)
      else:
        raise KtgError(kind: "type",
          msg: "-> requires context! or prototype!, got " & typeName(result),
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
      elif current.kind == vkPrototype:
        let key = $idx
        current = current.proto.get(key)
      else:
        raise KtgError(kind: "type",
          msg: "cannot index " & typeName(current) & " with dynamic path", data: idx)
    # Static word segment: literal field lookup
    elif current.kind == vkContext:
      current = current.ctx.get(seg)
    elif current.kind == vkPrototype:
      current = current.proto.get(seg)
    elif current.kind == vkMap:
      if seg in current.mapEntries:
        current = current.mapEntries[seg]
      else:
        raise KtgError(kind: "undefined", msg: seg & " not found in map", data: nil)
    elif current.kind == vkPair:
      case seg
      of "x": current = ktgInt(int64(current.px))
      of "y": current = ktgInt(int64(current.py))
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
  of vkContext, vkPrototype:
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

      # @global words write to global scope
      if val.wordName in eval.globals:
        eval.global.set(val.wordName, rhs)
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
          elif current.kind == vkPrototype:
            raise KtgError(kind: "type",
              msg: "cannot set path on prototype! (immutable)",
              data: current)
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
          else:
            raise KtgError(kind: "type",
              msg: "cannot set on " & typeName(current), data: current)
        elif current.kind == vkContext:
          current.ctx.set(lastSeg, rhs)
        elif current.kind == vkMap:
          current.mapEntries[lastSeg] = rhs
        elif current.kind == vkPrototype:
          raise KtgError(kind: "type",
            msg: "cannot set path on prototype! (immutable)",
            data: current)
        else:
          raise KtgError(kind: "type",
            msg: "cannot set field on " & typeName(current),
            data: current)
        return rhs

      # Auto-generation for prototype! assignment
      if rhs.kind == vkPrototype:
        let name = val.wordName
        let lowerName = toKebabCase(name)
        let customType = lowerName & "!"
        let constructorName = "make-" & lowerName

        # Store the prototype name on the prototype
        rhs.proto.name = name

        # Check for name collisions
        if ctx.has(customType):
          raise KtgError(kind: "name-collision",
            msg: "'" & customType & "' already exists in scope",
            data: nil)
        if ctx.has(constructorName):
          raise KtgError(kind: "name-collision",
            msg: "'" & constructorName & "' already exists in scope",
            data: nil)

        # Register the type predicate: name? checks structural match
        let fieldSpecs = rhs.proto.fieldSpecs
        ctx.set(customType, ktgType(customType))

        # Register type predicate function: checks if value has all fields
        let predicateName = lowerName & "?"
        if not ctx.has(predicateName):
          # Capture fieldSpecs for the closure
          let specs = fieldSpecs
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

        # Register constructor: make-name arg1 arg2 ...
        # Args match required fields in declaration order
        let protoVal = rhs
        let requiredFields = block:
          var rf: seq[FieldSpec] = @[]
          for fs in fieldSpecs:
            if not fs.hasDefault:
              rf.add(fs)
          rf
        let arity = requiredFields.len
        ctx.set(constructorName, KtgValue(kind: vkNative,
          nativeFn: KtgNative(name: constructorName, arity: arity, fn: proc(
              args: seq[KtgValue], ep: pointer): KtgValue =
            let eval = cast[Evaluator](ep)
            # Build an overrides block with set-words
            var overrideVals: seq[KtgValue] = @[]
            for i, fs in requiredFields:
              overrideVals.add(ktgWord(fs.name, wkSetWord))
              overrideVals.add(args[i])
            let overrideBlock = ktgBlock(overrideVals)
            # Call make directly
            let makeVal = eval.currentCtx.get("make")
            let makeArgs = @[protoVal, overrideBlock]
            makeVal.nativeFn.fn(makeArgs, ep)
          ),
          line: 0))

      # set in current scope (always shadows)
      ctx.set(val.wordName, rhs)
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

      # @global word: value — declare and set in global scope
      # @global word — mark existing word as global
      # @global [words] — mark multiple words as global
      if val.wordName == "global":
        if pos < vals.len:
          let next = vals[pos]
          # @global word: value
          if next.kind == vkWord and next.wordKind == wkSetWord:
            pos += 1
            var rhs = eval.evalNext(vals, pos, ctx)
            eval.applyInfix(rhs, vals, pos, ctx)
            eval.global.set(next.wordName, rhs)
            eval.globals.incl(next.wordName)
            return rhs
          # @global [words]
          if next.kind == vkBlock:
            pos += 1
            for v in next.blockVals:
              if v.kind == vkWord and v.wordKind == wkWord:
                eval.globals.incl(v.wordName)
            return ktgNone()
          # @global word
          if next.kind == vkWord and next.wordKind == wkWord:
            pos += 1
            eval.globals.incl(next.wordName)
            return ktgNone()
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

    eval.callStack.add(StackFrame(name: native.name, file: "", line: 0))
    let savedCtx = eval.currentCtx
    eval.currentCtx = ctx
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

proc preprocess*(eval: Evaluator, ast: seq[KtgValue]): seq[KtgValue] =
  ## Walk the AST looking for @preprocess meta-words followed by blocks,
  ## and @#inline meta-words followed by blocks (inline preprocess #[expr]).
  ## Evaluate those blocks in a preprocess context with `emit` to splice
  ## results into the output AST.
  var hasPreprocess = false
  for v in ast:
    if v.kind == vkWord and v.wordKind == wkMetaWord and
       v.wordName in ["preprocess", "inline"]:
      hasPreprocess = true
      break
  if not hasPreprocess:
    return ast

  result = @[]
  var i = 0
  while i < ast.len:
    if ast[i].kind == vkWord and ast[i].wordKind == wkMetaWord and
       ast[i].wordName == "inline" and i + 1 < ast.len and
       ast[i + 1].kind == vkBlock:
      # Inline preprocess: #[expr] — evaluate and splice result.
      # If result is a block, splice its contents (multi-node). Otherwise splice the value.
      let value = eval.evalBlock(ast[i + 1].blockVals, eval.global)
      if value != nil and value.kind != vkNone:
        if value.kind == vkBlock:
          for v in value.blockVals:
            result.add(v)
        else:
          result.add(value)
      i += 2
    elif ast[i].kind == vkWord and ast[i].wordKind == wkMetaWord and
       ast[i].wordName == "preprocess" and i + 1 < ast.len and
       ast[i + 1].kind == vkBlock:
      # Set up a preprocess context with `emit`
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

      # Evaluate the preprocess block
      discard eval.evalBlock(ast[i + 1].blockVals, ppCtx)

      # Splice emitted values into the result
      for v in emitted:
        result.add(v)

      i += 2
    else:
      result.add(ast[i])
      i += 1


# --- Convenience ---

proc evalString*(eval: Evaluator, src: string): KtgValue =
  let ast = parseSource(src)
  let processed = eval.preprocess(ast)
  eval.evalBlock(processed, eval.global)

proc getOutput*(eval: Evaluator): string =
  eval.output.join("\n")

proc clearOutput*(eval: Evaluator) =
  eval.output = @[]
