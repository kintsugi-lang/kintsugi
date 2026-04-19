import std/[strutils, tables, algorithm, sets]
import ../core/[types, equality]
import dialect, evaluator
import natives_math, natives_io, natives_convert

proc native(ctx: KtgContext, name: string, arity: int, fn: NativeFnProc,
            compilable = true) =
  ctx.set(name, KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: name, arity: arity, fn: fn,
                        compilable: compilable),
    line: 0))

proc deepCopyValue*(val: KtgValue): KtgValue =
  case val.kind
  of vkBlock:
    var newVals: seq[KtgValue] = @[]
    for v in val.blockVals:
      newVals.add(deepCopyValue(v))
    ktgBlock(newVals)
  of vkContext:
    let newCtx = newContext(val.ctx.parent)
    for key, v in val.ctx.entries:
      newCtx.set(key, deepCopyValue(v))
    KtgValue(kind: vkContext, ctx: newCtx, line: val.line)
  of vkString:
    ktgString(val.strVal)
  of vkMap:
    var newEntries = initOrderedTable[string, KtgValue]()
    for key, v in val.mapEntries:
      newEntries[key] = deepCopyValue(v)
    KtgValue(kind: vkMap, mapEntries: newEntries, line: val.line)
  of vkSet:
    KtgValue(kind: vkSet, setMembers: val.setMembers, line: val.line)
  of vkObject:
    var newEntries = initOrderedTable[string, KtgValue]()
    for key, v in val.obj.entries:
      newEntries[key] = deepCopyValue(v)
    KtgValue(kind: vkObject,
      obj: newObject(newEntries, val.obj.fieldSpecs, val.obj.name),
      line: val.line)
  else:
    val


proc seriesAt(val: KtgValue, idx: int, funcName: string): KtgValue =
  ## Access element at 0-based index from a block or string.
  ## Raises KtgError on type mismatch or out-of-range.
  case val.kind
  of vkBlock:
    if idx < 0 or idx >= val.blockVals.len:
      raise KtgError(kind: "range",
        msg: funcName & ": index out of range for block of length " & $val.blockVals.len,
        data: nil)
    return val.blockVals[idx]
  of vkString:
    if idx < 0 or idx >= val.strVal.len:
      raise KtgError(kind: "range",
        msg: funcName & ": index out of range for string of length " & $val.strVal.len,
        data: nil)
    return ktgString($val.strVal[idx])
  else:
    raise KtgError(kind: "type",
      msg: funcName & " expects series (block! or string!), got " & typeName(val),
      data: nil)

proc registerNatives*(eval: Evaluator) =
  let ctx = eval.global

  # --- Logic aliases (words, not keywords — usable in dialects) ---
  ctx.set("on", ktgLogic(true))
  ctx.set("yes", ktgLogic(true))
  ctx.set("off", ktgLogic(false))
  ctx.set("no", ktgLogic(false))

  # --- Output ---


  block:
    let printNative = KtgNative(
      name: "print",
      arity: 1,
      refinements: @[RefinementSpec(name: "no-newline", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        let s = $args[0]
        eval.output.add(s)
        if "no-newline" in eval.currentRefinements:
          when not defined(js):
            stdout.write(s)
            stdout.flushFile()
          else:
            echo s
        else:
          echo s
        ktgNone()
    )
    ctx.set("print", KtgValue(kind: vkNative, nativeFn: printNative, line: 0))

  ctx.native("probe", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    let s = $args[0]
    eval.output.add(s)
    echo s
    args[0]
  )

  # --- Control flow ---

  ctx.native("if", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if isTruthy(args[0]):
      if args[1].kind == vkBlock:
        return eval.evalBlock(args[1].blockVals, eval.currentCtx)
    ktgNone()
  )

  ctx.native("either", 3, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if isTruthy(args[0]):
      if args[1].kind == vkBlock:
        return eval.evalBlock(args[1].blockVals, eval.currentCtx)
      return args[1]
    else:
      if args[2].kind == vkBlock:
        return eval.evalBlock(args[2].blockVals, eval.currentCtx)
      return args[2]
  )

  ctx.native("unless", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if not isTruthy(args[0]):
      if args[1].kind == vkBlock:
        return eval.evalBlock(args[1].blockVals, eval.currentCtx)
    ktgNone()
  )

  ctx.native("not", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgLogic(not isTruthy(args[0]))
  )

  ctx.native("return", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    raise ReturnSignal(value: args[0])
  )

  ctx.native("break", 0, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    raise BreakSignal()
  )

  # --- Type introspection ---

  ctx.native("type", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ## For `make Enemy [...]` instances, report the source object's kebab-cased
    ## name (e.g. `enemy!`) instead of the bare `context!` carrier type.
    if args[0].kind == vkContext and args[0].ctx.instanceOf.len > 0:
      return ktgType(toKebabCase(args[0].ctx.instanceOf) & "!")
    ktgType(typeName(args[0]))
  )

  # type predicates — use a factory to capture each value properly
  proc makeTypePredicate(expected: string): NativeFnProc =
    return proc(args: seq[KtgValue], ep: pointer): KtgValue =
      ktgLogic(typeName(args[0]) == expected)

  for name in ["integer", "float", "string", "logic", "none", "money",
               "pair", "tuple", "date", "time", "file", "url", "email",
               "block", "paren", "map", "set", "context", "object",
               "function", "native", "word", "type"]:
    ctx.native(name & "?", 1, makeTypePredicate(name & "!"))

  # Override function? to also match native! (callables)
  ctx.native("function?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgLogic(args[0].kind in {vkFunction, vkNative})
  )

  ctx.native("number?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgLogic(args[0].kind in {vkInteger, vkFloat})
  )

  # --- is? — unified type checking ---

  const builtinTypes = ["integer!", "float!", "string!", "logic!", "none!",
    "money!", "pair!", "tuple!", "date!", "time!", "file!", "url!", "email!",
    "block!", "paren!", "map!", "set!", "context!", "object!",
    "function!", "native!", "word!", "type!", "set-word!", "get-word!",
    "lit-word!", "meta-word!", "op!"]

  ctx.native("is?", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    let typeArg = args[0]
    let value = args[1]

    # Case 1: type! value — e.g., is? integer! 42
    if typeArg.kind == vkType:
      # Check if this is a custom type value (from @type)
      if typeArg.customType != nil:
        return ktgLogic(eval.matchesCustomType(value, typeArg.customType, eval.currentCtx))

      let tn = typeArg.typeName

      # Phantom custom type: look in typeEnv first.
      if tn in eval.typeEnv:
        return ktgLogic(eval.matchesCustomType(value, eval.typeEnv[tn], eval.currentCtx))

      # Built-in type: direct match
      if tn in builtinTypes:
        return ktgLogic(typeName(value) == tn)

      # Type union: number! matches integer! or float!
      if tn == "number!":
        return ktgLogic(value.kind in {vkInteger, vkFloat})
      if tn == "any-word!":
        return ktgLogic(value.kind == vkWord)
      if tn == "scalar!":
        return ktgLogic(value.kind in {vkInteger, vkFloat, vkPair, vkTuple,
                                        vkDate, vkTime, vkMoney})

      # Custom type: look up in context first (for legacy code that still
      # binds the type value directly)
      if eval.currentCtx.has(tn):
        let typeVal = eval.currentCtx.get(tn)
        if typeVal.customType != nil:
          return ktgLogic(eval.matchesCustomType(value, typeVal.customType, eval.currentCtx))

      # Custom type: look up predicate function (e.g., person! -> person?)
      let baseName = tn[0 .. ^2]  # strip trailing !
      let predicateName = baseName & "?"
      if eval.currentCtx.has(predicateName):
        let predFn = eval.currentCtx.get(predicateName)
        if isCallable(predFn):
          var predArgs = @[value]
          return predFn.nativeFn.fn(predArgs, ep)

      # Unknown type
      return ktgLogic(false)

    # Case 2: raw block rule — e.g., is? ['x integer!] [x 10]
    if typeArg.kind == vkBlock:
      # Treat as ad-hoc structural type rule
      let ct = CustomType(
        rule: typeArg.blockVals,
        guard: @[],
        isEnum: false,
        isStruct: true  # assume structural if it has lit-words
      )
      return ktgLogic(eval.matchesCustomType(value, ct, eval.currentCtx))

    # Case 3: object! — e.g., is? :Person p
    if typeArg.kind == vkObject:
      # Structural check: value must be a context with all fields from object
      if value.kind != vkContext:
        return ktgLogic(false)
      for fs in typeArg.obj.fieldSpecs:
        if fs.name notin value.ctx.entries:
          return ktgLogic(false)
      return ktgLogic(true)

    # Fallback
    ktgLogic(false)
  )

  # --- Series operations ---

  let lengthImpl = proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkBlock: ktgInt(int64(args[0].blockVals.len))
    of vkString: ktgInt(int64(args[0].strVal.len))
    of vkMap: ktgInt(int64(args[0].mapEntries.len))
    of vkSet: ktgInt(int64(args[0].setMembers.len))
    of vkContext: ktgInt(int64(args[0].ctx.entries.len))
    of vkObject: ktgInt(int64(args[0].obj.entries.len))
    of vkParen: ktgInt(int64(args[0].parenVals.len))
    else:
      raise KtgError(kind: "type", msg: "length not supported on " & typeName(args[0]), data: nil)
  ctx.native("length", 1, lengthImpl)

  ctx.native("empty?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkBlock: ktgLogic(args[0].blockVals.len == 0)
    of vkString: ktgLogic(args[0].strVal.len == 0)
    of vkMap: ktgLogic(args[0].mapEntries.len == 0)
    of vkContext: ktgLogic(args[0].ctx.entries.len == 0)
    of vkObject: ktgLogic(args[0].obj.entries.len == 0)
    else:
      raise KtgError(kind: "type", msg: "empty? not supported on " & typeName(args[0]), data: nil)
  )

  ctx.native("first", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    seriesAt(args[0], 0, "first")
  )

  ctx.native("second", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    seriesAt(args[0], 1, "second")
  )

  ctx.native("last", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let idx = case args[0].kind
      of vkBlock: args[0].blockVals.len - 1
      of vkString: args[0].strVal.len - 1
      else: -1  # seriesAt will raise on type mismatch
    seriesAt(args[0], idx, "last")
  )

  ctx.native("pick", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[1].kind != vkInteger:
      raise KtgError(kind: "type", msg: "pick expects integer! as index", data: args[1])
    let idx = int(args[1].intVal) - 1  # 1-based to 0-based
    seriesAt(args[0], idx, "pick")
  )

  block:
    let appendNative = KtgNative(
      name: "append",
      arity: 2,
      refinements: @[RefinementSpec(name: "only", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        let only = "only" in eval.currentRefinements
        if args[0].kind == vkBlock:
          if args[1].kind == vkBlock and not only:
            # Splice: append [1 2] [3 4] → [1 2 3 4]
            for v in args[1].blockVals:
              args[0].blockVals.add(v)
          else:
            # Single element (or /only): append [1 2] 3 → [1 2 3]
            args[0].blockVals.add(args[1])
          return args[0]
        if args[0].kind == vkString:
          raise KtgError(kind: "type", msg: "strings are immutable; use rejoin or join to build new strings", data: nil)
        raise KtgError(kind: "type", msg: "append expects block!, got " & typeName(args[0]), data: nil)
    )
    ctx.set("append", KtgValue(kind: vkNative, nativeFn: appendNative, line: 0))

  block:
    let copyNative = KtgNative(
      name: "copy",
      arity: 1,
      refinements: @[RefinementSpec(name: "deep", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        let isDeep = "deep" in eval.currentRefinements
        case args[0].kind
        of vkBlock:
          if isDeep:
            return deepCopyValue(args[0])
          ktgBlock(args[0].blockVals[0..^1])
        of vkString:
          ktgString(args[0].strVal)
        of vkContext:
          if isDeep:
            return deepCopyValue(args[0])
          let newCtx = newContext(args[0].ctx.parent)
          for key, v in args[0].ctx.entries:
            newCtx.set(key, v)
          KtgValue(kind: vkContext, ctx: newCtx, line: args[0].line)
        else:
          raise KtgError(kind: "type", msg: "copy not supported on " & typeName(args[0]), data: nil)
    )
    ctx.set("copy", KtgValue(kind: vkNative, nativeFn: copyNative, line: 0))

  ctx.native("insert", 3, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkBlock and args[2].kind == vkInteger:
      let idx = int(args[2].intVal) - 1  # 1-based
      if idx < 0 or idx > args[0].blockVals.len:
        raise KtgError(kind: "range", msg: "insert index out of range", data: args[2])
      args[0].blockVals.insert(args[1], idx)
      return args[0]
    # String insert: immutable, returns new string
    if args[0].kind == vkString and args[1].kind == vkString and args[2].kind == vkInteger:
      let s = args[0].strVal
      let ins = args[1].strVal
      let idx = int(args[2].intVal) - 1
      if idx < 0 or idx > s.len:
        raise KtgError(kind: "range", msg: "insert index out of range", data: args[2])
      return ktgString(s[0 ..< idx] & ins & s[idx .. ^1])
    raise KtgError(kind: "type", msg: "insert expects block!/string!, value, integer!", data: nil)
  )

  ctx.native("remove", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkBlock and args[1].kind == vkInteger:
      let idx = int(args[1].intVal) - 1  # 1-based
      if idx < 0 or idx >= args[0].blockVals.len:
        raise KtgError(kind: "range", msg: "remove index out of range", data: args[1])
      args[0].blockVals.delete(idx)
      return args[0]
    # String remove: immutable, returns new string
    if args[0].kind == vkString and args[1].kind == vkInteger:
      let s = args[0].strVal
      let idx = int(args[1].intVal) - 1
      if idx < 0 or idx >= s.len:
        raise KtgError(kind: "range", msg: "remove index out of range", data: args[1])
      return ktgString(s[0 ..< idx] & s[idx + 1 .. ^1])
    raise KtgError(kind: "type", msg: "remove expects block!/string! and integer!", data: nil)
  )

  ctx.native("select", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    # key-value lookup in flat blocks or maps/contexts
    if args[0].kind == vkBlock and args[1].kind == vkWord:
      let name = args[1].wordName
      let blk = args[0].blockVals
      for i in 0 ..< blk.len - 1:
        if blk[i].kind == vkWord and blk[i].wordName.toLowerAscii == name.toLowerAscii:
          return blk[i + 1]
      return ktgNone()
    if args[0].kind == vkMap:
      let name = if args[1].kind == vkWord: args[1].wordName
                 elif args[1].kind == vkString: args[1].strVal
                 else: ""
      if name in args[0].mapEntries: return args[0].mapEntries[name]
      return ktgNone()
    if args[0].kind == vkContext:
      let name = if args[1].kind == vkWord: args[1].wordName else: ""
      if name in args[0].ctx.entries: return args[0].ctx.entries[name]
      return ktgNone()
    ktgNone()
  )

  ctx.native("has?", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkBlock:
      for v in args[0].blockVals:
        if valuesEqual(v, args[1]): return ktgLogic(true)
      return ktgLogic(false)
    of vkString:
      if args[1].kind == vkString:
        return ktgLogic(args[1].strVal in args[0].strVal)
    of vkMap:
      if args[1].kind == vkWord:
        return ktgLogic(args[1].wordName in args[0].mapEntries)
      if args[1].kind == vkString:
        return ktgLogic(args[1].strVal in args[0].mapEntries)
    of vkContext:
      if args[1].kind == vkWord:
        return ktgLogic(args[1].wordName in args[0].ctx.entries)
    of vkSet:
      return ktgLogic($args[1] in args[0].setMembers)
    else: discard
    ktgLogic(false)
  )



  # --- find: unified search for blocks and strings ---

  block:
    let findNative = KtgNative(
      name: "find",
      arity: 2,
      refinements: @[RefinementSpec(name: "where", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        if "where" in eval.currentRefinements:
          # find/where block predicate — first element matching predicate
          if args[0].kind != vkBlock:
            raise KtgError(kind: "type", msg: "find/where expects block!", data: nil)
          if not isCallable(args[1]):
            raise KtgError(kind: "type", msg: "find/where expects function as predicate", data: nil)
          for item in args[0].blockVals:
            var predArgs = @[item]
            var predPos = 0
            let res = eval.callCallable(args[1], predArgs, predPos, eval.currentCtx)
            if isTruthy(res): return item
          return ktgNone()
        case args[0].kind
        of vkBlock:
          for i, v in args[0].blockVals:
            if valuesEqual(v, args[1]): return ktgInt(int64(i + 1))
          return ktgNone()
        of vkString:
          let needle = $args[1]
          let idx = args[0].strVal.find(needle)
          if idx >= 0: return ktgInt(int64(idx + 1))
          return ktgNone()
        else:
          raise KtgError(kind: "type", msg: "find expects block! or string!, got " & typeName(args[0]), data: nil)
    )
    ctx.set("find", KtgValue(kind: vkNative, nativeFn: findNative, line: 0))

  # --- reverse: unified for blocks and strings ---

  ctx.native("reverse", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkBlock:
      var reversed: seq[KtgValue] = @[]
      for i in countdown(args[0].blockVals.len - 1, 0):
        reversed.add(args[0].blockVals[i])
      return ktgBlock(reversed)
    of vkString:
      var s = ""
      for i in countdown(args[0].strVal.len - 1, 0):
        s.add(args[0].strVal[i])
      return ktgString(s)
    else:
      raise KtgError(kind: "type", msg: "reverse expects block! or string!, got " & typeName(args[0]), data: nil)
  )

  # --- String operations ---

  block:
    let joinNative = KtgNative(
      name: "join",
      arity: 1,
      refinements: @[RefinementSpec(name: "with", params: @[ParamSpec(name: "delim")])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        let delim = if "with" in eval.currentRefinements and args.len > 1:
                      $args[1]
                    else: ""
        if args[0].kind != vkBlock:
          raise KtgError(kind: "type", msg: "join expects block!", data: nil)
        var parts: seq[string] = @[]
        for v in args[0].blockVals:
          parts.add($v)
        ktgString(parts.join(delim))
    )
    ctx.set("join", KtgValue(kind: vkNative, nativeFn: joinNative, line: 0))

  block:
    let rejoinNative = KtgNative(
      name: "rejoin",
      arity: 1,
      refinements: @[RefinementSpec(name: "with", params: @[ParamSpec(name: "delim")])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        let delim = if "with" in eval.currentRefinements and args.len > 1:
                      $args[1]
                    else: ""
        if args[0].kind != vkBlock:
          return ktgString($args[0])
        # Full reduce: run the evaluator over the block, same as `reduce`,
        # so infix operators and calls evaluate correctly. Then stringify.
        var reduced: seq[KtgValue] = @[]
        var pos = 0
        while pos < args[0].blockVals.len:
          var r = eval.evalNext(args[0].blockVals, pos, eval.currentCtx)
          eval.applyInfix(r, args[0].blockVals, pos, eval.currentCtx)
          reduced.add(r)
        var parts: seq[string] = @[]
        for v in reduced:
          parts.add($v)
        ktgString(parts.join(delim))
    )
    ctx.set("rejoin", KtgValue(kind: vkNative, nativeFn: rejoinNative, line: 0))

  ctx.native("trim", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkString:
      return ktgString(args[0].strVal.strip)
    raise KtgError(kind: "type", msg: "trim expects string!", data: nil)
  )

  ctx.native("uppercase", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkString:
      return ktgString(args[0].strVal.toUpperAscii)
    raise KtgError(kind: "type", msg: "uppercase expects string!", data: nil)
  )

  ctx.native("lowercase", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkString:
      return ktgString(args[0].strVal.toLowerAscii)
    raise KtgError(kind: "type", msg: "lowercase expects string!", data: nil)
  )

  ctx.native("starts-with?", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkString and args[1].kind == vkString:
      return ktgLogic(args[0].strVal.startsWith(args[1].strVal))
    raise KtgError(kind: "type", msg: "starts-with? expects string! and string!", data: nil)
  )

  ctx.native("ends-with?", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkString and args[1].kind == vkString:
      return ktgLogic(args[0].strVal.endsWith(args[1].strVal))
    raise KtgError(kind: "type", msg: "ends-with? expects string! and string!", data: nil)
  )

  block:
    let padNative = KtgNative(
      name: "pad",
      arity: 3,
      refinements: @[RefinementSpec(name: "right", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        let isRight = "right" in eval.currentRefinements
        if args[0].kind == vkString:
          let fill = $args[2]
          let width = if args[1].kind == vkInteger: int(args[1].intVal) else: 0
          var s = args[0].strVal
          while s.len < width:
            if isRight: s = s & fill
            else: s = fill & s
          return ktgString(s)
        if args[0].kind == vkBlock:
          let width = if args[1].kind == vkInteger: int(args[1].intVal) else: 0
          var blk = ktgBlock(args[0].blockVals[0..^1])
          while blk.blockVals.len < width:
            if isRight: blk.blockVals.add(args[2])
            else: blk.blockVals.insert(args[2], 0)
          return blk
        raise KtgError(kind: "type", msg: "pad expects string! or block!, got " & typeName(args[0]), data: nil)
    )
    ctx.set("pad", KtgValue(kind: vkNative, nativeFn: padNative, line: 0))

  ctx.native("split", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkString and args[1].kind == vkString:
      let parts = args[0].strVal.split(args[1].strVal)
      var vals: seq[KtgValue] = @[]
      for p in parts:
        vals.add(ktgString(p))
      return ktgBlock(vals)
    raise KtgError(kind: "type", msg: "split expects string! and string!", data: nil)
  )

  # --- replace: 3-arg with /first refinement ---
  block:
    let replaceNative = KtgNative(
      name: "replace",
      arity: 3,
      refinements: @[RefinementSpec(name: "first", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        let firstOnly = "first" in eval.currentRefinements
        if args[0].kind == vkString and args[1].kind == vkString and args[2].kind == vkString:
          if firstOnly:
            let idx = args[0].strVal.find(args[1].strVal)
            if idx < 0:
              return ktgString(args[0].strVal)
            return ktgString(
              args[0].strVal[0 ..< idx] &
              args[2].strVal &
              args[0].strVal[idx + args[1].strVal.len .. ^1])
          return ktgString(args[0].strVal.replace(args[1].strVal, args[2].strVal))
        if args[0].kind == vkBlock:
          var items: seq[KtgValue] = @[]
          var replaced = false
          for v in args[0].blockVals:
            if valuesEqual(v, args[1]) and not (firstOnly and replaced):
              items.add(args[2])
              replaced = true
            else:
              items.add(v)
          return ktgBlock(items)
        raise KtgError(kind: "type", msg: "replace expects string! or block!, got " & typeName(args[0]), data: nil)
    )
    ctx.set("replace", KtgValue(kind: vkNative, nativeFn: replaceNative, line: 0))

  ctx.native("subset", 3, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind notin {vkString, vkBlock}:
      raise KtgError(kind: "type", msg: "subset expects string! or block!, got " & typeName(args[0]), data: nil)
    if args[1].kind != vkInteger or args[2].kind != vkInteger:
      raise KtgError(kind: "type", msg: "subset expects series integer! integer!", data: nil)
    let start = int(args[1].intVal) - 1  # 1-based
    let length = int(args[2].intVal)
    if length < 0:
      raise KtgError(kind: "range", msg: "subset length must be non-negative", data: args[2])
    case args[0].kind
    of vkString:
      let s = args[0].strVal
      if start < 0 or start >= s.len:
        raise KtgError(kind: "range", msg: "subset start out of range", data: args[1])
      let endIdx = min(start + length, s.len)
      ktgString(s[start ..< endIdx])
    of vkBlock:
      let b = args[0].blockVals
      if start < 0 or start >= b.len:
        raise KtgError(kind: "range", msg: "subset start out of range", data: args[1])
      let endIdx = min(start + length, b.len)
      ktgBlock(b[start ..< endIdx])
    else: ktgNone()
  )

  # --- Block evaluation ---

  ctx.native("scope", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "scope expects block!", data: nil)
    let childCtx = eval.currentCtx.child
    childCtx.localOnly = true
    eval.evalBlock(args[0].blockVals, childCtx)
  )

  ctx.native("reduce", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if args[0].kind == vkBlock:
      var results: seq[KtgValue] = @[]
      var pos = 0
      while pos < args[0].blockVals.len:
        var r = eval.evalNext(args[0].blockVals, pos, eval.currentCtx)
        eval.applyInfix(r, args[0].blockVals, pos, eval.currentCtx)
        results.add(r)
      return ktgBlock(results)
    args[0]
  )

  ctx.native("all?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if args[0].kind == vkBlock:
      var pos = 0
      while pos < args[0].blockVals.len:
        var r = eval.evalNext(args[0].blockVals, pos, eval.currentCtx)
        eval.applyInfix(r, args[0].blockVals, pos, eval.currentCtx)
        if not isTruthy(r):
          return ktgLogic(false)
      return ktgLogic(true)
    ktgNone()
  )

  ctx.native("any?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if args[0].kind == vkBlock:
      var pos = 0
      while pos < args[0].blockVals.len:
        var r = eval.evalNext(args[0].blockVals, pos, eval.currentCtx)
        eval.applyInfix(r, args[0].blockVals, pos, eval.currentCtx)
        if isTruthy(r):
          return ktgLogic(true)
      return ktgLogic(false)
    ktgNone()
  )

  ctx.native("words", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    var names: seq[KtgValue] = @[]
    case args[0].kind
    of vkContext:
      for key in args[0].ctx.entries.keys:
        names.add(ktgWord(key, wkWord))
    of vkObject:
      for key in args[0].obj.entries.keys:
        names.add(ktgWord(key, wkWord))
    else:
      raise KtgError(kind: "type", msg: "words expects context! or object!", data: nil)
    ktgBlock(names)
  )

  block:
    let mergeNative = KtgNative(
      name: "merge",
      arity: 2,
      refinements: @[
        RefinementSpec(name: "deep", params: @[]),
        RefinementSpec(name: "freeze", params: @[])
      ],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        let isDeep = "deep" in eval.currentRefinements
        let doFreeze = "freeze" in eval.currentRefinements

        proc getEntries(val: KtgValue): OrderedTable[string, KtgValue] =
          case val.kind
          of vkContext: val.ctx.entries
          of vkObject: val.obj.entries
          else:
            raise KtgError(kind: "type",
              msg: "merge expects context! or object!, got " & typeName(val), data: val)

        let aEntries = getEntries(args[0])
        let bEntries = getEntries(args[1])

        let merged = newContext(eval.global)
        for key, val in aEntries:
          if isDeep:
            merged.set(key, deepCopyValue(val))
          else:
            merged.set(key, val)
        for key, val in bEntries:
          if val.kind != vkNone:
            if isDeep:
              merged.set(key, deepCopyValue(val))
            else:
              merged.set(key, val)

        if doFreeze:
          KtgValue(kind: vkObject,
            obj: newObject(merged.entries), line: 0)
        else:
          KtgValue(kind: vkContext, ctx: merged, line: 0)
    )
    ctx.set("merge", KtgValue(kind: vkNative, nativeFn: mergeNative, line: 0))

  # --- Context/Object ---

  ctx.native("context", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if args[0].kind == vkBlock:
      let ctxInner = newContext(eval.currentCtx)
      ctxInner.localOnly = true
      discard eval.evalBlock(args[0].blockVals, ctxInner)
      return KtgValue(kind: vkContext, ctx: ctxInner, line: 0)
    raise KtgError(kind: "type", msg: "context expects block!", data: nil)
  )

  # --- Freeze ---

  block:
    proc freezeValue(val: KtgValue, deep: bool): KtgValue =
      case val.kind
      of vkContext:
        var entries = initOrderedTable[string, KtgValue]()
        for key, v in val.ctx.entries:
          if deep and v.kind == vkContext:
            entries[key] = freezeValue(v, true)
          else:
            entries[key] = v
        KtgValue(kind: vkObject, obj: newObject(entries), line: val.line)
      of vkObject:
        if deep:
          var entries = initOrderedTable[string, KtgValue]()
          for key, v in val.obj.entries:
            if v.kind == vkContext:
              entries[key] = freezeValue(v, true)
            else:
              entries[key] = v
          KtgValue(kind: vkObject,
            obj: newObject(entries, val.obj.fieldSpecs, val.obj.name),
            line: val.line)
        else:
          val
      else:
        raise KtgError(kind: "type",
          msg: "freeze expects context! or object!, got " & typeName(val), data: val)

    let freezeNative = KtgNative(
      name: "freeze",
      arity: 1,
      refinements: @[RefinementSpec(name: "deep", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        let deep = "deep" in eval.currentRefinements
        freezeValue(args[0], deep)
    )
    ctx.set("freeze", KtgValue(kind: vkNative, nativeFn: freezeNative, line: 0))

  ctx.native("frozen?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgLogic(args[0].kind == vkObject)
  )

  # --- Function creation ---

  ctx.native("function", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if args[0].kind != vkBlock or args[1].kind != vkBlock:
      raise KtgError(kind: "type", msg: "function expects [spec] [body]", data: nil)

    let spec = parseFuncSpec(args[0].blockVals)
    let fn = KtgFunc(
      params: spec.params,
      refinements: spec.refinements,
      returnType: spec.returnType,
      body: args[1].blockVals,
      closure: eval.currentCtx
    )
    KtgValue(kind: vkFunction, fn: fn, line: 0)
  )

  # --- does: zero-arg function shorthand ---

  ctx.native("does", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "does expects [body]", data: nil)
    let fn = KtgFunc(
      params: @[],
      refinements: @[],
      returnType: "",
      body: args[0].blockVals,
      closure: eval.currentCtx
    )
    KtgValue(kind: vkFunction, fn: fn, line: 0)
  )

  # --- Error handling ---

  ctx.native("error", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    # Arity 2: `error <kind:lit-word> <payload:any>`. Payload is whatever
    # the caller attaches -- typically a string, but any value works.
    # The internal KtgError.msg is derived from the payload for Nim-side
    # formatting (CLI error printer); user code only sees `kind` and `data`.
    let kind = if args[0].kind == vkWord: args[0].wordName else: "user"
    let msg = if args[1].kind == vkString: args[1].strVal else: $args[1]
    raise KtgError(kind: kind, msg: msg, data: args[1])
  )

  block: # try with /handle refinement
    let tryNative = KtgNative(
      name: "try",
      arity: 1,
      refinements: @[RefinementSpec(name: "handle", params: @[
        ParamSpec(name: "handler", typeName: "")
      ])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        if args[0].kind != vkBlock:
          raise KtgError(kind: "type", msg: "try expects block!", data: nil)
        let hasHandle = "handle" in eval.currentRefinements
        var handler: KtgValue = nil
        if hasHandle and args.len > 1:
          handler = args[1]
        # Result shape: {kind, data}. Success: kind=none, data=value.
        # Failure: kind=lit-word, data=error payload.
        let resultCtx = newContext()
        proc finish(ctx: KtgContext, kind: KtgValue, data: KtgValue) =
          ctx.set("kind", kind)
          ctx.set("data", data)
        try:
          let value = eval.evalBlock(args[0].blockVals, eval.currentCtx)
          finish(resultCtx, ktgNone(), value)
        except KtgError as e:
          # kind is stored as a bare word so `print r/kind` reads "math"
          # rather than "'math". Match patterns ['math] still dispatch
          # against a bare word by name — wordKind isn't checked.
          let errKind = ktgWord(e.kind, wkWord)
          let errData = if e.data != nil: e.data else: ktgString(e.msg)
          if hasHandle and handler != nil and isCallable(handler):
            # Handler receives the failure result context (with /kind and /data).
            try:
              let errCtx = newContext()
              finish(errCtx, errKind, errData)
              var handlerArgs = @[KtgValue(kind: vkContext, ctx: errCtx, line: 0)]
              var handlerPos = 0
              let handlerResult = eval.callCallable(handler, handlerArgs, handlerPos, eval.currentCtx)
              finish(resultCtx, ktgNone(), handlerResult)
            except KtgError as he:
              let heData = if he.data != nil: he.data else: ktgString(he.msg)
              finish(resultCtx, ktgWord(he.kind, wkWord), heData)
          else:
            finish(resultCtx, errKind, errData)
        KtgValue(kind: vkContext, ctx: resultCtx, line: 0)
    )
    ctx.set("try", KtgValue(kind: vkNative, nativeFn: tryNative, line: 0))

  # --- Set (destructuring) ---

  ctx.native("set", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "set expects [words] and value", data: nil)

    let names = args[0].blockVals
    let source = args[1]

    if source.kind == vkBlock:
      # positional destructuring with @rest support
      var srcIdx = 0
      for i, name in names:
        if name.kind == vkWord and name.wordKind == wkMetaWord:
          # @name — collect remaining elements into a block
          var remaining: seq[KtgValue] = @[]
          for j in srcIdx ..< source.blockVals.len:
            remaining.add(source.blockVals[j])
          eval.currentCtx.set(name.wordName, ktgBlock(remaining))
          break  # @rest consumes everything, nothing after it
        elif name.kind == vkWord and srcIdx < source.blockVals.len:
          eval.currentCtx.set(name.wordName, source.blockVals[srcIdx])
          srcIdx += 1
    elif source.kind == vkContext:
      # named destructuring
      for name in names:
        if name.kind == vkWord and name.wordName in source.ctx.entries:
          eval.currentCtx.set(name.wordName, source.ctx.entries[name.wordName])
    elif source.kind == vkObject:
      # named destructuring from object
      for name in names:
        if name.kind == vkWord and name.wordName in source.obj.entries:
          eval.currentCtx.set(name.wordName, source.obj.entries[name.wordName])

    source
  )


  # --- Apply ---

  ctx.native("apply", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    let fn = args[0]
    if args[1].kind != vkBlock:
      raise KtgError(kind: "type", msg: "apply expects function and block of args", data: nil)
    var pos = 0
    eval.callCallable(fn, args[1].blockVals, pos, eval.currentCtx)
  )

  # --- Sort ---

  block:
    let sortNative = KtgNative(
      name: "sort",
      arity: 1,
      refinements: @[RefinementSpec(name: "by", params: @[
        ParamSpec(name: "key-fn", typeName: "")
      ])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)
        if args[0].kind notin {vkBlock, vkString}:
          raise KtgError(kind: "type", msg: "sort expects block! or string!", data: nil)

        # String: sort characters and return new string (immutable)
        if args[0].kind == vkString:
          var chars: seq[char] = @[]
          for c in args[0].strVal: chars.add(c)
          chars.sort()
          var s = newString(chars.len)
          for i, c in chars: s[i] = c
          return ktgString(s)

        if "by" in eval.currentRefinements and args.len > 1:
          # sort/by block key-fn
          let keyFn = args[1]
          args[0].blockVals.sort(proc(a, b: KtgValue): int =
            proc callKeyFn(val: KtgValue): KtgValue =
              var fnArgs = @[val]
              var fnPos = 0
              eval.callCallable(keyFn, fnArgs, fnPos, eval.currentCtx)

            let aKeyVal = callKeyFn(a)
            let bKeyVal = callKeyFn(b)

            if aKeyVal.kind == vkInteger and bKeyVal.kind == vkInteger:
              return cmp(aKeyVal.intVal, bKeyVal.intVal)
            if aKeyVal.kind in {vkInteger, vkFloat} and bKeyVal.kind in {vkInteger, vkFloat}:
              let af = if aKeyVal.kind == vkInteger: float64(aKeyVal.intVal) else: aKeyVal.floatVal
              let bf = if bKeyVal.kind == vkInteger: float64(bKeyVal.intVal) else: bKeyVal.floatVal
              return cmp(af, bf)
            if aKeyVal.kind == vkString and bKeyVal.kind == vkString:
              return cmp(aKeyVal.strVal, bKeyVal.strVal)
            if aKeyVal.kind == vkMoney and bKeyVal.kind == vkMoney:
              return cmp(aKeyVal.cents, bKeyVal.cents)
            0
          )
          return args[0]

        args[0].blockVals.sort(proc(a, b: KtgValue): int =
          if a.kind == vkInteger and b.kind == vkInteger:
            return cmp(a.intVal, b.intVal)
          if a.kind in {vkInteger, vkFloat} and b.kind in {vkInteger, vkFloat}:
            let af = if a.kind == vkInteger: float64(a.intVal) else: a.floatVal
            let bf = if b.kind == vkInteger: float64(b.intVal) else: b.floatVal
            return cmp(af, bf)
          if a.kind == vkString and b.kind == vkString:
            return cmp(a.strVal, b.strVal)
          0
        )
        args[0]
    )
    ctx.set("sort", KtgValue(kind: vkNative, nativeFn: sortNative, line: 0))

  # --- Make ---
  # NOTE: `make` is registered in object_dialect.nim with full field validation,
  # type checking, required field checks, and self-binding support.
  # map!/set! handling is also there.

  # --- Set operations ---

  ctx.native("union", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkSet and args[1].kind == vkSet:
      var combined = args[0].setMembers
      for m in args[1].setMembers:
        combined.incl(m)
      return KtgValue(kind: vkSet, setMembers: combined, line: 0)
    raise KtgError(kind: "type", msg: "union expects two set! values", data: nil)
  )

  ctx.native("intersect", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkSet and args[1].kind == vkSet:
      var res = initHashSet[string]()
      for m in args[0].setMembers:
        if m in args[1].setMembers:
          res.incl(m)
      return KtgValue(kind: vkSet, setMembers: res, line: 0)
    raise KtgError(kind: "type", msg: "intersect expects two set! values", data: nil)
  )

  # --- Sub-module registrations ---
  eval.registerMathNatives()
  eval.registerIoNatives()
  eval.registerConvertNatives()

  # (load/save/import/exports/bindings/system/capture are in natives_io.nim)
  # (math/trig/random are in natives_math.nim)
  # (to conversions are in natives_convert.nim)

