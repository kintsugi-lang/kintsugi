import std/[strutils, tables, math, algorithm, sets, os, times, random]
import ../core/[types, equality]
import ../parse/parser
import dialect, evaluator

proc native(ctx: KtgContext, name: string, arity: int, fn: NativeFnProc) =
  ctx.set(name, KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: name, arity: arity, fn: fn),
    line: 0))


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
        let eval = cast[Evaluator](ep)
        let s = $args[0]
        eval.output.add(s)
        if "no-newline" in eval.currentRefinements:
          stdout.write(s)
          stdout.flushFile()
        else:
          echo s
        ktgNone()
    )
    ctx.set("print", KtgValue(kind: vkNative, nativeFn: printNative, line: 0))

  ctx.native("probe", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    let s = $args[0]
    eval.output.add(s)
    echo s
    args[0]
  )

  # --- Control flow ---

  ctx.native("if", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if isTruthy(args[0]):
      if args[1].kind == vkBlock:
        return eval.evalBlock(args[1].blockVals, eval.currentCtx)
    ktgNone()
  )

  ctx.native("either", 3, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
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
    let eval = cast[Evaluator](ep)
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
    let eval = cast[Evaluator](ep)
    let typeArg = args[0]
    let value = args[1]

    # Case 1: type! value — e.g., is? integer! 42
    if typeArg.kind == vkType:
      # Check if this is a custom type value (from @type)
      if typeArg.customType != nil:
        return ktgLogic(eval.matchesCustomType(value, typeArg.customType, eval.currentCtx))

      let tn = typeArg.typeName

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

      # Custom type: look up in context first (for @type-defined types)
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

    # Case 3: object! prototype — e.g., is? :Person p
    if typeArg.kind == vkObject:
      # Structural check: value must be a context with all fields from prototype
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

  ctx.native("size?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkBlock: ktgInt(int64(args[0].blockVals.len))
    of vkString: ktgInt(int64(args[0].strVal.len))
    of vkMap: ktgInt(int64(args[0].mapEntries.len))
    of vkSet: ktgInt(int64(args[0].setMembers.len))
    of vkContext: ktgInt(int64(args[0].ctx.entries.len))
    of vkObject: ktgInt(int64(args[0].obj.entries.len))
    of vkParen: ktgInt(int64(args[0].parenVals.len))
    else:
      raise KtgError(kind: "type", msg: "size? not supported on " & typeName(args[0]), data: nil)
  )

  # length? as alias
  ctx.native("length?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkBlock: ktgInt(int64(args[0].blockVals.len))
    of vkString: ktgInt(int64(args[0].strVal.len))
    of vkMap: ktgInt(int64(args[0].mapEntries.len))
    of vkSet: ktgInt(int64(args[0].setMembers.len))
    of vkContext: ktgInt(int64(args[0].ctx.entries.len))
    of vkObject: ktgInt(int64(args[0].obj.entries.len))
    of vkParen: ktgInt(int64(args[0].parenVals.len))
    else:
      raise KtgError(kind: "type", msg: "length? not supported on " & typeName(args[0]), data: nil)
  )

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
    case args[0].kind
    of vkBlock:
      if args[0].blockVals.len == 0:
        raise KtgError(kind: "range", msg: "first on empty block", data: nil)
      return args[0].blockVals[0]
    of vkString:
      if args[0].strVal.len == 0:
        raise KtgError(kind: "range", msg: "first on empty string", data: nil)
      return ktgString($args[0].strVal[0])
    else:
      raise KtgError(kind: "type", msg: "first expects series (block! or string!), got " & typeName(args[0]), data: nil)
  )

  ctx.native("second", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkBlock:
      if args[0].blockVals.len < 2:
        raise KtgError(kind: "range", msg: "second on block with fewer than 2 elements", data: nil)
      return args[0].blockVals[1]
    of vkString:
      if args[0].strVal.len < 2:
        raise KtgError(kind: "range", msg: "second on string with fewer than 2 characters", data: nil)
      return ktgString($args[0].strVal[1])
    else:
      raise KtgError(kind: "type", msg: "second expects series (block! or string!), got " & typeName(args[0]), data: nil)
  )

  ctx.native("last", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkBlock:
      if args[0].blockVals.len == 0:
        raise KtgError(kind: "range", msg: "last on empty block", data: nil)
      return args[0].blockVals[^1]
    of vkString:
      if args[0].strVal.len == 0:
        raise KtgError(kind: "range", msg: "last on empty string", data: nil)
      return ktgString($args[0].strVal[^1])
    else:
      raise KtgError(kind: "type", msg: "last expects series (block! or string!), got " & typeName(args[0]), data: nil)
  )

  ctx.native("pick", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[1].kind != vkInteger:
      raise KtgError(kind: "type", msg: "pick expects integer! as index", data: args[1])
    let idx = int(args[1].intVal) - 1  # 1-based
    case args[0].kind
    of vkBlock:
      if idx < 0 or idx >= args[0].blockVals.len:
        raise KtgError(kind: "range",
          msg: "index " & $args[1].intVal & " out of range for block of length " & $args[0].blockVals.len,
          data: args[1])
      return args[0].blockVals[idx]
    of vkString:
      if idx < 0 or idx >= args[0].strVal.len:
        raise KtgError(kind: "range",
          msg: "index " & $args[1].intVal & " out of range for string of length " & $args[0].strVal.len,
          data: args[1])
      return ktgString($args[0].strVal[idx])
    else:
      raise KtgError(kind: "type", msg: "pick expects block! or string!, got " & typeName(args[0]), data: nil)
  )

  block:
    let appendNative = KtgNative(
      name: "append",
      arity: 2,
      refinements: @[RefinementSpec(name: "only", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = cast[Evaluator](ep)
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
          args[0].strVal.add($args[1])
          return args[0]
        raise KtgError(kind: "type", msg: "append expects block! or string!, got " & typeName(args[0]), data: nil)
    )
    ctx.set("append", KtgValue(kind: vkNative, nativeFn: appendNative, line: 0))

  block:
    proc deepCopy(val: KtgValue): KtgValue =
      case val.kind
      of vkBlock:
        var newVals: seq[KtgValue] = @[]
        for v in val.blockVals:
          newVals.add(deepCopy(v))
        ktgBlock(newVals)
      of vkContext:
        let newCtx = newContext(val.ctx.parent)
        for key, v in val.ctx.entries:
          newCtx.set(key, deepCopy(v))
        KtgValue(kind: vkContext, ctx: newCtx, line: val.line)
      of vkString:
        ktgString(val.strVal)
      else:
        val

    let copyNative = KtgNative(
      name: "copy",
      arity: 1,
      refinements: @[RefinementSpec(name: "deep", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = cast[Evaluator](ep)
        let isDeep = "deep" in eval.currentRefinements
        case args[0].kind
        of vkBlock:
          if isDeep:
            return deepCopy(args[0])
          ktgBlock(args[0].blockVals[0..^1])
        of vkString:
          ktgString(args[0].strVal)
        of vkContext:
          if isDeep:
            return deepCopy(args[0])
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
      args[0].blockVals.insert(args[1], idx)
      return args[0]
    raise KtgError(kind: "type", msg: "insert expects block!, value, integer!", data: nil)
  )

  ctx.native("remove", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkBlock and args[1].kind == vkInteger:
      let idx = int(args[1].intVal) - 1  # 1-based
      if idx < 0 or idx >= args[0].blockVals.len:
        raise KtgError(kind: "range", msg: "remove index out of range", data: args[1])
      args[0].blockVals.delete(idx)
      return args[0]
    raise KtgError(kind: "type", msg: "remove expects block! and integer!", data: nil)
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
        let eval = cast[Evaluator](ep)
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

  ctx.native("join", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgString($args[0] & $args[1])
  )

  ctx.native("rejoin", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkBlock:
      let eval = cast[Evaluator](ep)
      var s = ""
      for v in args[0].blockVals:
        # evaluate parens inside rejoin
        if v.kind == vkParen:
          s &= $eval.evalBlock(v.parenVals, eval.currentCtx)
        elif v.kind == vkWord and v.wordKind == wkWord:
          if v.wordName.contains('/'):
            let (head, segments) = parsePath(v.wordName)
            let headVal = eval.currentCtx.get(head)
            s &= $eval.navigatePath(headVal, segments, eval.currentCtx)
          else:
            s &= $eval.currentCtx.get(v.wordName)
        else:
          s &= $v
      return ktgString(s)
    ktgString($args[0])
  )

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
        let eval = cast[Evaluator](ep)
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

  ctx.native("replace", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    # replace is replace-all by default
    if args[0].kind == vkString and args[1].kind == vkString:
      # need 3 args actually
      discard
    ktgNone()
  )

  # override replace with 3-arg version + /first refinement
  block:
    let replaceNative = KtgNative(
      name: "replace",
      arity: 3,
      refinements: @[RefinementSpec(name: "first", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = cast[Evaluator](ep)
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

  ctx.native("substring", 3, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind != vkString:
      raise KtgError(kind: "type", msg: "substring expects string!, got " & typeName(args[0]), data: nil)
    if args[1].kind != vkInteger or args[2].kind != vkInteger:
      raise KtgError(kind: "type", msg: "substring expects string! integer! integer!", data: nil)
    let start = int(args[1].intVal) - 1  # 1-based
    let length = int(args[2].intVal)
    let s = args[0].strVal
    if start < 0 or start > s.len:
      raise KtgError(kind: "range", msg: "substring start out of range", data: args[1])
    let endIdx = min(start + length, s.len)
    ktgString(s[start ..< endIdx])
  )

  # --- byte/char: character code conversion ---

  ctx.native("byte", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind != vkString or args[0].strVal.len == 0:
      raise KtgError(kind: "type", msg: "byte expects non-empty string!", data: nil)
    ktgInt(int64(ord(args[0].strVal[0])))
  )

  ctx.native("char", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind != vkInteger:
      raise KtgError(kind: "type", msg: "char expects integer!", data: nil)
    let code = int(args[0].intVal)
    if code < 0 or code > 127:
      raise KtgError(kind: "range", msg: "char code must be 0-127", data: args[0])
    ktgString($chr(code))
  )

  # --- read: unified input primitive ---
  # read %file → string
  # read/dir %path → block of filenames
  # read/lines %file → block of strings
  block:
    let readNative = KtgNative(
      name: "read",
      arity: 1,
      refinements: @[
        RefinementSpec(name: "dir", params: @[]),
        RefinementSpec(name: "lines", params: @[]),
        RefinementSpec(name: "stdin", params: @[])
      ],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = cast[Evaluator](ep)

        if "stdin" in eval.currentRefinements:
          # read/stdin "prompt" — read a line from stdin
          let prompt = $args[0]
          if prompt.len > 0 and prompt != "none":
            stdout.write(prompt)
            stdout.flushFile()
          var line: string
          if stdin.readLine(line):
            return ktgString(line)
          return ktgNone()

        let path = case args[0].kind
          of vkString: args[0].strVal
          of vkFile: args[0].filePath
          else:
            raise KtgError(kind: "type", msg: "read expects string! or file!", data: nil)

        if "dir" in eval.currentRefinements:
          if not dirExists(path):
            raise KtgError(kind: "io", msg: "directory not found: " & path, data: args[0])
          var entries: seq[KtgValue] = @[]
          for kind, entry in walkDir(path):
            entries.add(ktgString(lastPathPart(entry)))
          entries.sort(proc(a, b: KtgValue): int = cmp(a.strVal, b.strVal))
          return ktgBlock(entries)

        if "lines" in eval.currentRefinements:
          if not fileExists(path):
            raise KtgError(kind: "io", msg: "file not found: " & path, data: args[0])
          let content = readFile(path)
          var lines: seq[KtgValue] = @[]
          for line in content.splitLines:
            lines.add(ktgString(line))
          return ktgBlock(lines)

        if not fileExists(path):
          raise KtgError(kind: "io", msg: "file not found: " & path, data: args[0])
        ktgString(readFile(path))
    )
    ctx.set("read", KtgValue(kind: vkNative, nativeFn: readNative, line: 0))

  # --- write: unified output primitive ---
  ctx.native("write", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let path = case args[0].kind
      of vkString: args[0].strVal
      of vkFile: args[0].filePath
      else:
        raise KtgError(kind: "type", msg: "write expects string! or file!", data: nil)
    if args[1].kind != vkString:
      raise KtgError(kind: "type", msg: "write expects string! as content", data: nil)
    writeFile(path, args[1].strVal)
    ktgNone()
  )

  ctx.native("dir?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let path = case args[0].kind
      of vkString: args[0].strVal
      of vkFile: args[0].filePath
      else:
        raise KtgError(kind: "type", msg: "dir? expects string! or file!", data: nil)
    ktgLogic(dirExists(path))
  )

  ctx.native("file?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let path = case args[0].kind
      of vkString: args[0].strVal
      of vkFile: args[0].filePath
      else:
        raise KtgError(kind: "type", msg: "file? expects string! or file!", data: nil)
    ktgLogic(fileExists(path))
  )

  ctx.native("exit", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let code = case args[0].kind
      of vkInteger: int(args[0].intVal)
      else: 0
    raise ExitSignal(code: code)
  )

  # --- Time ---

  ctx.native("now", 0, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgInt(toUnix(getTime()))
  )

  # time/now and date/now as a context with methods
  block:
    let timeCtx = newContext()
    timeCtx.set("now", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "time/now", arity: 0, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        let t = now()
        KtgValue(kind: vkTime, hour: uint8(t.hour), minute: uint8(t.minute),
                 second: uint8(t.second), line: 0)
      ), line: 0))
    timeCtx.set("from-epoch", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "time/from-epoch", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkInteger:
          raise KtgError(kind: "type", msg: "time/from-epoch expects integer!", data: nil)
        let dt = fromUnix(args[0].intVal).local
        KtgValue(kind: vkTime, hour: uint8(dt.hour), minute: uint8(dt.minute),
                 second: uint8(dt.second), line: 0)
      ), line: 0))
    timeCtx.set("hours", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "time/hours", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkTime:
          raise KtgError(kind: "type", msg: "time/hours expects time!", data: nil)
        ktgInt(int64(args[0].hour))
      ), line: 0))
    timeCtx.set("minutes", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "time/minutes", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkTime:
          raise KtgError(kind: "type", msg: "time/minutes expects time!", data: nil)
        ktgInt(int64(args[0].minute))
      ), line: 0))
    timeCtx.set("seconds", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "time/seconds", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkTime:
          raise KtgError(kind: "type", msg: "time/seconds expects time!", data: nil)
        ktgInt(int64(args[0].second))
      ), line: 0))
    timeCtx.set("to-seconds", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "time/to-seconds", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkTime:
          raise KtgError(kind: "type", msg: "time/to-seconds expects time!", data: nil)
        ktgInt(int64(args[0].hour) * 3600 + int64(args[0].minute) * 60 + int64(args[0].second))
      ), line: 0))
    ctx.set("time", KtgValue(kind: vkObject, obj: freeze(timeCtx), line: 0))

  block:
    let dateCtx = newContext()
    dateCtx.set("now", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "date/now", arity: 0, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        let d = now()
        KtgValue(kind: vkDate, year: int16(d.year), month: uint8(ord(d.month)),
                 day: uint8(d.monthday), line: 0)
      ), line: 0))
    dateCtx.set("from-epoch", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "date/from-epoch", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkInteger:
          raise KtgError(kind: "type", msg: "date/from-epoch expects integer!", data: nil)
        let dt = fromUnix(args[0].intVal).local
        KtgValue(kind: vkDate, year: int16(dt.year), month: uint8(ord(dt.month)),
                 day: uint8(dt.monthday), line: 0)
      ), line: 0))
    dateCtx.set("year", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "date/year", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkDate:
          raise KtgError(kind: "type", msg: "date/year expects date!", data: nil)
        ktgInt(int64(args[0].year))
      ), line: 0))
    dateCtx.set("month", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "date/month", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkDate:
          raise KtgError(kind: "type", msg: "date/month expects date!", data: nil)
        ktgInt(int64(args[0].month))
      ), line: 0))
    dateCtx.set("day", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "date/day", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkDate:
          raise KtgError(kind: "type", msg: "date/day expects date!", data: nil)
        ktgInt(int64(args[0].day))
      ), line: 0))
    dateCtx.set("weekday", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "date/weekday", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkDate:
          raise KtgError(kind: "type", msg: "date/weekday expects date!", data: nil)
        let dt = dateTime(int(args[0].year), Month(args[0].month), MonthdayRange(args[0].day), 0, 0, 0)
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        ktgString(names[ord(dt.weekday)])
      ), line: 0))
    ctx.set("date", KtgValue(kind: vkObject, obj: freeze(dateCtx), line: 0))

  # --- Math ---

  ctx.native("abs", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkInteger: ktgInt(abs(args[0].intVal))
    of vkFloat: ktgFloat(abs(args[0].floatVal))
    else: raise KtgError(kind: "type", msg: "abs expects number!", data: nil)
  )

  ctx.native("negate", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkInteger: ktgInt(-args[0].intVal)
    of vkFloat: ktgFloat(-args[0].floatVal)
    else: raise KtgError(kind: "type", msg: "negate expects number!", data: nil)
  )

  ctx.native("min", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkInteger and args[1].kind == vkInteger:
      return ktgInt(min(args[0].intVal, args[1].intVal))
    if args[0].kind in {vkInteger, vkFloat} and args[1].kind in {vkInteger, vkFloat}:
      let a = if args[0].kind == vkInteger: float64(args[0].intVal) else: args[0].floatVal
      let b = if args[1].kind == vkInteger: float64(args[1].intVal) else: args[1].floatVal
      return ktgFloat(min(a, b))
    raise KtgError(kind: "type", msg: "min expects number!", data: nil)
  )

  ctx.native("max", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkInteger and args[1].kind == vkInteger:
      return ktgInt(max(args[0].intVal, args[1].intVal))
    if args[0].kind in {vkInteger, vkFloat} and args[1].kind in {vkInteger, vkFloat}:
      let a = if args[0].kind == vkInteger: float64(args[0].intVal) else: args[0].floatVal
      let b = if args[1].kind == vkInteger: float64(args[1].intVal) else: args[1].floatVal
      return ktgFloat(max(a, b))
    raise KtgError(kind: "type", msg: "max expects number!", data: nil)
  )

  ctx.native("round", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    let v = case args[0].kind
      of vkFloat: args[0].floatVal
      of vkInteger: float64(args[0].intVal)
      else: raise KtgError(kind: "type", msg: "round expects number!", data: nil)
    if "down" in eval.currentRefinements:
      # truncate toward zero
      return ktgInt(int64(trunc(v)))
    elif "up" in eval.currentRefinements:
      # away from zero (ceiling for positive, floor for negative)
      if v >= 0.0:
        return ktgInt(int64(ceil(v)))
      else:
        return ktgInt(int64(floor(v)))
    else:
      return ktgInt(int64(round(v)))
  )

  ctx.native("odd?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkInteger:
      return ktgLogic(args[0].intVal mod 2 != 0)
    raise KtgError(kind: "type", msg: "odd? expects integer!", data: nil)
  )

  ctx.native("even?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkInteger:
      return ktgLogic(args[0].intVal mod 2 == 0)
    raise KtgError(kind: "type", msg: "even? expects integer!", data: nil)
  )

  ctx.native("sqrt", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let v = case args[0].kind
      of vkInteger: float64(args[0].intVal)
      of vkFloat: args[0].floatVal
      else: raise KtgError(kind: "type", msg: "sqrt expects number!", data: nil)
    ktgFloat(sqrt(v))
  )

  # Helper to extract float from number arg
  template numArg(a: KtgValue, fname: string): float64 =
    case a.kind
    of vkInteger: float64(a.intVal)
    of vkFloat: a.floatVal
    else: raise KtgError(kind: "type", msg: fname & " expects number!", data: nil)

  # --- Trig (radians) ---

  ctx.native("sin", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(sin(numArg(args[0], "sin")))
  )

  ctx.native("cos", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(cos(numArg(args[0], "cos")))
  )

  ctx.native("tan", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(tan(numArg(args[0], "tan")))
  )

  ctx.native("asin", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(arcsin(numArg(args[0], "asin")))
  )

  ctx.native("acos", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(arccos(numArg(args[0], "acos")))
  )

  ctx.native("atan2", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(arctan2(numArg(args[0], "atan2"), numArg(args[1], "atan2")))
  )

  # --- Exponentiation / logarithms ---

  ctx.native("pow", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let base = numArg(args[0], "pow")
    let exp = numArg(args[1], "pow")
    let r = pow(base, exp)
    if args[0].kind == vkInteger and args[1].kind == vkInteger and
       exp >= 0.0 and r == floor(r) and r < float64(high(int64)):
      ktgInt(int64(r))
    else:
      ktgFloat(r)
  )

  ctx.native("exp", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(exp(numArg(args[0], "exp")))
  )

  ctx.native("log", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(ln(numArg(args[0], "log")))
  )

  ctx.native("log10", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(log10(numArg(args[0], "log10")))
  )

  # --- Degree/radian conversion ---

  ctx.native("to-degrees", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(radToDeg(numArg(args[0], "to-degrees")))
  )

  ctx.native("to-radians", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgFloat(degToRad(numArg(args[0], "to-radians")))
  )

  # --- Floor / ceil ---

  ctx.native("floor", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgInt(int64(floor(numArg(args[0], "floor"))))
  )

  ctx.native("ceil", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgInt(int64(ceil(numArg(args[0], "ceil"))))
  )

  # --- Constants ---

  ctx.set("pi", ktgFloat(PI))

  # --- Random ---
  # random N → float in [0, N) or int in [0, N) via /int
  # random/int N → integer in [0, N)
  # random/choice block → pick random element

  block:
    randomize()  # seed from system clock
    let randomNative = KtgNative(
      name: "random",
      arity: 1,
      refinements: @[
        RefinementSpec(name: "int", params: @[]),
        RefinementSpec(name: "range", params: @[ParamSpec(name: "max", typeName: "")]),
        RefinementSpec(name: "choice", params: @[]),
        RefinementSpec(name: "seed", params: @[])
      ],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = cast[Evaluator](ep)

        if "seed" in eval.currentRefinements:
          let s = case args[0].kind
            of vkInteger: int(args[0].intVal)
            else: raise KtgError(kind: "type", msg: "random/seed expects integer!", data: nil)
          randomize(s)
          return ktgNone()

        if "choice" in eval.currentRefinements:
          if args[0].kind != vkBlock:
            raise KtgError(kind: "type", msg: "random/choice expects block!", data: nil)
          let blk = args[0].blockVals
          if blk.len == 0:
            return ktgNone()
          return blk[rand(blk.len - 1)]

        # /range: random/range lo hi → float in [lo, hi)
        # /int/range: random/int/range lo hi → integer in [lo, hi]
        if "range" in eval.currentRefinements:
          let lo = numArg(args[0], "random/range")
          # /range has 1 param (max), consumed after regular args
          # args layout: [lo, ...refinement params...]
          # /int has 0 params, /range has 1 param → args[1] is max
          let hi = numArg(args[1], "random/range")
          if "int" in eval.currentRefinements:
            return ktgInt(int64(rand(int(hi) - int(lo)) + int(lo)))
          return ktgFloat(lo + rand(hi - lo))

        if "int" in eval.currentRefinements:
          let n = case args[0].kind
            of vkInteger: int(args[0].intVal)
            else: raise KtgError(kind: "type", msg: "random/int expects integer!", data: nil)
          return ktgInt(int64(rand(n - 1)))

        # Default: float in [0, N)
        let n = numArg(args[0], "random")
        ktgFloat(rand(n))
    )
    ctx.set("random", KtgValue(kind: vkNative, nativeFn: randomNative, line: 0))

  # --- Homoiconic ---

  ctx.native("do", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if args[0].kind == vkBlock:
      let useCtx = if args[0].boundCtx != nil: args[0].boundCtx
                   else: eval.currentCtx
      return eval.evalBlock(args[0].blockVals, useCtx)
    args[0]
  )

  ctx.native("bind", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "bind expects block! and context!", data: nil)
    if args[1].kind != vkContext:
      raise KtgError(kind: "type", msg: "bind expects block! and context!, got " & typeName(args[1]), data: nil)
    args[0].boundCtx = args[1].ctx
    args[0]
  )

  ctx.native("reduce", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
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

  block: # compose with /deep refinement
    proc composeBlock(eval: Evaluator, blk: seq[KtgValue], deep: bool): seq[KtgValue] =
      var results: seq[KtgValue] = @[]
      for v in blk:
        if v.kind == vkParen:
          results.add(eval.evalBlock(v.parenVals, eval.currentCtx))
        elif deep and v.kind == vkBlock:
          results.add(ktgBlock(composeBlock(eval, v.blockVals, deep)))
        else:
          results.add(v)
      results

    let composeNative = KtgNative(
      name: "compose",
      arity: 1,
      refinements: @[RefinementSpec(name: "deep", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = cast[Evaluator](ep)
        if args[0].kind == vkBlock:
          let deep = "deep" in eval.currentRefinements
          return ktgBlock(composeBlock(eval, args[0].blockVals, deep))
        args[0]
    )
    ctx.set("compose", KtgValue(kind: vkNative, nativeFn: composeNative, line: 0))

  ctx.native("all", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if args[0].kind == vkBlock:
      var lastVal: KtgValue = ktgLogic(true)
      var pos = 0
      while pos < args[0].blockVals.len:
        var r = eval.evalNext(args[0].blockVals, pos, eval.currentCtx)
        eval.applyInfix(r, args[0].blockVals, pos, eval.currentCtx)
        if not isTruthy(r):
          return r
        lastVal = r
      return lastVal
    ktgNone()
  )

  ctx.native("any", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if args[0].kind == vkBlock:
      var pos = 0
      while pos < args[0].blockVals.len:
        var r = eval.evalNext(args[0].blockVals, pos, eval.currentCtx)
        eval.applyInfix(r, args[0].blockVals, pos, eval.currentCtx)
        if isTruthy(r):
          return r
      return ktgNone()
    ktgNone()
  )

  ctx.native("words-of", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    var names: seq[KtgValue] = @[]
    case args[0].kind
    of vkContext:
      for key in args[0].ctx.entries.keys:
        names.add(ktgWord(key, wkWord))
    of vkObject:
      for key in args[0].obj.entries.keys:
        names.add(ktgWord(key, wkWord))
    else:
      raise KtgError(kind: "type", msg: "words-of expects context! or object!", data: nil)
    ktgBlock(names)
  )

  # --- Context/Object ---

  ctx.native("context", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if args[0].kind == vkBlock:
      let ctxInner = newContext(eval.currentCtx)
      discard eval.evalBlock(args[0].blockVals, ctxInner)
      return KtgValue(kind: vkContext, ctx: ctxInner, line: 0)
    raise KtgError(kind: "type", msg: "context expects block!", data: nil)
  )

  block:
    proc deepFreeze(val: KtgValue): KtgValue =
      if val.kind == vkContext:
        for key, v in val.ctx.entries:
          if v.kind == vkContext:
            val.ctx.entries[key] = deepFreeze(v)
        return KtgValue(kind: vkObject, obj: freeze(val.ctx), line: 0)
      val

    let freezeNative = KtgNative(
      name: "freeze",
      arity: 1,
      refinements: @[RefinementSpec(name: "deep", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = cast[Evaluator](ep)
        if args[0].kind == vkContext:
          if "deep" in eval.currentRefinements:
            return deepFreeze(args[0])
          return KtgValue(kind: vkObject, obj: freeze(args[0].ctx), line: 0)
        if args[0].kind == vkObject:
          return args[0]  # already frozen
        raise KtgError(kind: "type", msg: "freeze expects context!", data: nil)
    )
    ctx.set("freeze", KtgValue(kind: vkNative, nativeFn: freezeNative, line: 0))

  ctx.native("frozen?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgLogic(args[0].kind == vkObject)
  )

  # --- Function creation ---

  ctx.native("function", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if args[0].kind != vkBlock or args[1].kind != vkBlock:
      raise KtgError(kind: "type", msg: "function expects [spec] [body]", data: nil)

    var params: seq[ParamSpec] = @[]
    var refinements: seq[RefinementSpec] = @[]
    var returnType = ""
    let spec = args[0].blockVals
    var i = 0
    var inRefinement = false  # true when we've seen a /word
    while i < spec.len:
      let s = spec[i]
      # Refinement declaration: /name (single word token starting with /)
      if s.kind == vkWord and s.wordKind == wkWord and s.wordName.startsWith("/"):
        let refName = s.wordName[1..^1]
        refinements.add(RefinementSpec(name: refName, params: @[]))
        inRefinement = true
        i += 1
        continue
      if s.kind == vkWord and s.wordKind == wkWord:
        var pname = s.wordName
        var ptype = ""
        var elemType = ""
        # check for type block
        if i + 1 < spec.len and spec[i + 1].kind == vkBlock:
          i += 1
          let typeBlock = spec[i].blockVals
          if typeBlock.len > 0:
            # Handle typed blocks: [block! integer!] — container + element type
            if typeBlock.len == 2 and typeBlock[0].kind == vkType and
                 typeBlock[0].typeName == "block!" and typeBlock[1].kind == vkType:
              ptype = "block!"
              elemType = typeBlock[1].typeName
            else:
              ptype = $typeBlock[0]
        if inRefinement:
          # This is a refinement parameter
          if refinements.len > 0:
            refinements[^1].params.add(ParamSpec(name: pname, typeName: ptype, elementType: elemType))
        else:
          params.add(ParamSpec(name: pname, typeName: ptype, elementType: elemType))
      elif s.kind == vkWord and s.wordKind == wkSetWord and s.wordName == "return":
        if i + 1 < spec.len and spec[i + 1].kind == vkBlock:
          i += 1
          let typeBlock = spec[i].blockVals
          if typeBlock.len > 0:
            returnType = $typeBlock[0]
      i += 1

    let fn = KtgFunc(
      params: params,
      refinements: refinements,
      returnType: returnType,
      body: args[1].blockVals,
      closure: eval.currentCtx
    )
    KtgValue(kind: vkFunction, fn: fn, line: 0)
  )

  # --- does: zero-arg function shorthand ---

  ctx.native("does", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
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

  ctx.native("error", 3, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let kind = if args[0].kind == vkWord: args[0].wordName else: "user"
    let msg = if args[1].kind == vkString: args[1].strVal else: $args[1]
    raise KtgError(kind: kind, msg: msg, data: args[2])
  )

  block: # try with /handle refinement
    let tryNative = KtgNative(
      name: "try",
      arity: 1,
      refinements: @[RefinementSpec(name: "handle", params: @[
        ParamSpec(name: "handler", typeName: "")
      ])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = cast[Evaluator](ep)
        if args[0].kind != vkBlock:
          raise KtgError(kind: "type", msg: "try expects block!", data: nil)
        let hasHandle = "handle" in eval.currentRefinements
        # Handler is args[1] when /handle is active (consumed by refinement param handling)
        var handler: KtgValue = nil
        if hasHandle and args.len > 1:
          handler = args[1]
        let resultCtx = newContext()
        try:
          let value = eval.evalBlock(args[0].blockVals, eval.currentCtx)
          resultCtx.set("ok", ktgLogic(true))
          resultCtx.set("value", value)
          resultCtx.set("kind", ktgNone())
          resultCtx.set("message", ktgNone())
          resultCtx.set("data", ktgNone())
        except KtgError as e:
          let errKind = ktgWord(e.kind, wkLitWord)
          let errMsg = ktgString(e.msg)
          let errData = if e.data != nil: e.data else: ktgNone()
          if hasHandle and handler != nil and isCallable(handler):
            # Call handler with a single error context
            try:
              let errCtx = newContext()
              errCtx.set("kind", errKind)
              errCtx.set("message", errMsg)
              errCtx.set("data", errData)
              var handlerArgs = @[KtgValue(kind: vkContext, ctx: errCtx, line: 0)]
              var handlerPos = 0
              let handlerResult = eval.callCallable(handler, handlerArgs, handlerPos, eval.currentCtx)
              resultCtx.set("ok", ktgLogic(true))
              resultCtx.set("value", handlerResult)
              resultCtx.set("kind", ktgNone())
              resultCtx.set("message", ktgNone())
              resultCtx.set("data", ktgNone())
            except KtgError as he:
              resultCtx.set("ok", ktgLogic(false))
              resultCtx.set("value", ktgNone())
              resultCtx.set("kind", ktgWord(he.kind, wkLitWord))
              resultCtx.set("message", ktgString(he.msg))
              resultCtx.set("data", if he.data != nil: he.data else: ktgNone())
          else:
            resultCtx.set("ok", ktgLogic(false))
            resultCtx.set("value", ktgNone())
            resultCtx.set("kind", errKind)
            resultCtx.set("message", errMsg)
            resultCtx.set("data", errData)
        KtgValue(kind: vkContext, ctx: resultCtx, line: 0)
    )
    ctx.set("try", KtgValue(kind: vkNative, nativeFn: tryNative, line: 0))

  # --- Rethrow ---

  ctx.native("rethrow", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let val = args[0]
    if val.kind == vkContext:
      let kind = val.ctx.get("kind")
      let msg = val.ctx.get("message")
      let data = if val.ctx.has("data"): val.ctx.get("data") else: ktgNone()
      raise KtgError(
        kind: if kind.kind == vkWord: kind.wordName else: "user",
        msg: if msg.kind == vkString: msg.strVal else: $msg,
        data: data
      )
    raise KtgError(kind: "type", msg: "rethrow expects a try result context", data: nil)
  )

  # --- Set (destructuring) ---

  ctx.native("set", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
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

  # --- To (type conversion) ---

  ctx.native("to", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let target = if args[0].kind == vkType: args[0].typeName else: $args[0]
    let val = args[1]

    case target
    of "integer!":
      case val.kind
      of vkInteger: return val
      of vkFloat: return ktgInt(int64(val.floatVal))
      of vkString:
        try: return ktgInt(parseInt(val.strVal))
        except:
          try: return ktgInt(int64(parseFloat(val.strVal)))
          except: raise KtgError(kind: "type", msg: "cannot convert \"" & val.strVal & "\" to integer!", data: val)
      of vkMoney: return ktgInt(val.cents)
      of vkTime: return ktgInt(int64(val.hour) * 3600 + int64(val.minute) * 60 + int64(val.second))
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to integer!", data: val)

    of "float!":
      case val.kind
      of vkFloat: return val
      of vkInteger: return ktgFloat(float64(val.intVal))
      of vkString:
        try: return ktgFloat(parseFloat(val.strVal))
        except: raise KtgError(kind: "type", msg: "cannot convert \"" & val.strVal & "\" to float!", data: val)
      of vkMoney: return ktgFloat(float64(val.cents) / 100.0)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to float!", data: val)

    of "string!":
      if val.kind == vkWord:
        return ktgString(val.wordName)
      return ktgString($val)

    of "block!":
      case val.kind
      of vkBlock: return val
      of vkPair: return ktgBlock(@[ktgInt(int64(val.px)), ktgInt(int64(val.py))])
      of vkTuple:
        var vals: seq[KtgValue] = @[]
        for v in val.tupleVals: vals.add(ktgInt(int64(v)))
        return ktgBlock(vals)
      else: return ktgBlock(@[val])

    of "money!":
      case val.kind
      of vkMoney: return val
      of vkInteger: return ktgMoney(val.intVal * 100)
      of vkFloat: return ktgMoney(int64(round(val.floatVal * 100.0)))
      of vkString:
        try:
          let f = parseFloat(val.strVal)
          return ktgMoney(int64(round(f * 100.0)))
        except: raise KtgError(kind: "type", msg: "cannot convert to money!", data: val)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to money!", data: val)

    of "pair!":
      if val.kind == vkBlock and val.blockVals.len == 2:
        let x = if val.blockVals[0].kind == vkInteger: int32(val.blockVals[0].intVal) else: 0'i32
        let y = if val.blockVals[1].kind == vkInteger: int32(val.blockVals[1].intVal) else: 0'i32
        return ktgPair(x, y)
      if val.kind == vkString:
        let parts = val.strVal.split('x')
        if parts.len == 2:
          return ktgPair(int32(parseInt(parts[0])), int32(parseInt(parts[1])))
      raise KtgError(kind: "type", msg: "cannot convert to pair!", data: val)

    of "word!":
      if val.kind == vkString: return ktgWord(val.strVal, wkWord)
      if val.kind == vkWord: return ktgWord(val.wordName, wkWord)
      raise KtgError(kind: "type", msg: "cannot convert to word!", data: val)

    of "set-word!":
      if val.kind == vkString: return ktgWord(val.strVal, wkSetWord)
      if val.kind == vkWord: return ktgWord(val.wordName, wkSetWord)
      raise KtgError(kind: "type", msg: "cannot convert to set-word!", data: val)

    of "lit-word!":
      if val.kind == vkString: return ktgWord(val.strVal, wkLitWord)
      if val.kind == vkWord: return ktgWord(val.wordName, wkLitWord)
      raise KtgError(kind: "type", msg: "cannot convert to lit-word!", data: val)

    of "get-word!":
      if val.kind == vkString: return ktgWord(val.strVal, wkGetWord)
      if val.kind == vkWord: return ktgWord(val.wordName, wkGetWord)
      raise KtgError(kind: "type", msg: "cannot convert to get-word!", data: val)

    of "meta-word!":
      if val.kind == vkString: return ktgWord(val.strVal, wkMetaWord)
      if val.kind == vkWord: return ktgWord(val.wordName, wkMetaWord)
      raise KtgError(kind: "type", msg: "cannot convert to meta-word!", data: val)

    of "logic!":
      if val.kind == vkLogic: return val
      if val.kind == vkNone: return ktgLogic(false)
      if val.kind == vkString:
        if val.strVal == "true": return ktgLogic(true)
        if val.strVal == "false": return ktgLogic(false)
      raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to logic!", data: val)

    of "time!":
      case val.kind
      of vkTime: return val
      of vkInteger:
        # seconds to time
        let total = val.intVal
        let h = uint8((total div 3600) mod 24)
        let m = uint8((total mod 3600) div 60)
        let s = uint8(total mod 60)
        return KtgValue(kind: vkTime, hour: h, minute: m, second: s, line: 0)
      of vkString:
        let parts = val.strVal.split(':')
        if parts.len >= 2:
          let h = uint8(parseInt(parts[0]))
          let m = uint8(parseInt(parts[1]))
          let s = if parts.len >= 3: uint8(parseInt(parts[2])) else: 0'u8
          return KtgValue(kind: vkTime, hour: h, minute: m, second: s, line: 0)
        raise KtgError(kind: "type", msg: "cannot convert \"" & val.strVal & "\" to time!", data: val)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to time!", data: val)

    of "date!":
      case val.kind
      of vkDate: return val
      of vkString:
        let parts = val.strVal.split('-')
        if parts.len == 3:
          return KtgValue(kind: vkDate,
            year: int16(parseInt(parts[0])),
            month: uint8(parseInt(parts[1])),
            day: uint8(parseInt(parts[2])),
            line: 0)
        raise KtgError(kind: "type", msg: "cannot convert \"" & val.strVal & "\" to date!", data: val)
      of vkBlock:
        if val.blockVals.len == 3:
          let y = if val.blockVals[0].kind == vkInteger: int16(val.blockVals[0].intVal) else: 0'i16
          let m = if val.blockVals[1].kind == vkInteger: uint8(val.blockVals[1].intVal) else: 0'u8
          let d = if val.blockVals[2].kind == vkInteger: uint8(val.blockVals[2].intVal) else: 0'u8
          return KtgValue(kind: vkDate, year: y, month: m, day: d, line: 0)
        raise KtgError(kind: "type", msg: "cannot convert block to date! (need 3 elements)", data: val)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to date!", data: val)

    of "tuple!":
      case val.kind
      of vkTuple: return val
      of vkBlock:
        var vals: seq[uint8] = @[]
        for v in val.blockVals:
          if v.kind == vkInteger: vals.add(uint8(v.intVal))
          else: raise KtgError(kind: "type", msg: "tuple elements must be integers 0-255", data: v)
        return KtgValue(kind: vkTuple, tupleVals: vals, line: 0)
      of vkString:
        var vals: seq[uint8] = @[]
        for part in val.strVal.split('.'):
          vals.add(uint8(parseInt(part)))
        return KtgValue(kind: vkTuple, tupleVals: vals, line: 0)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to tuple!", data: val)

    of "file!":
      case val.kind
      of vkFile: return val
      of vkString: return ktgFile(val.strVal)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to file!", data: val)

    of "url!":
      case val.kind
      of vkUrl: return val
      of vkString: return ktgUrl(val.strVal)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to url!", data: val)

    of "email!":
      case val.kind
      of vkEmail: return val
      of vkString: return ktgEmail(val.strVal)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to email!", data: val)

    else:
      raise KtgError(kind: "type", msg: "unknown target type: " & target, data: nil)
  )

  # --- Apply ---

  ctx.native("apply", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    let fn = args[0]
    if args[1].kind != vkBlock:
      raise KtgError(kind: "type", msg: "apply expects function and block of args", data: nil)
    var pos = 0
    eval.callCallable(fn, args[1].blockVals, pos, eval.global)
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
        let eval = cast[Evaluator](ep)
        if args[0].kind != vkBlock:
          raise KtgError(kind: "type", msg: "sort expects block!", data: nil)

        if "by" in eval.currentRefinements and args.len > 1:
          # sort/by block key-fn
          let keyFn = args[1]
          args[0].blockVals.sort(proc(a, b: KtgValue): int =
            proc callKeyFn(val: KtgValue): KtgValue =
              if keyFn.kind == vkFunction:
                let f = keyFn.fn
                let funcCtx = f.closure.child
                if f.params.len > 0:
                  funcCtx.set(f.params[0].name, val)
                return eval.evalBlock(f.body, funcCtx)
              elif keyFn.kind == vkNative:
                return keyFn.nativeFn.fn(@[val], ep)
              else:
                return val

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

  # --- Charset (sugar for make set! from string characters) ---

  ctx.native("charset", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind != vkString:
      raise KtgError(kind: "type", msg: "charset expects string!", data: nil)
    var members = initHashSet[string]()
    for c in args[0].strVal:
      members.incl($c)
    KtgValue(kind: vkSet, setMembers: members, line: 0)
  )

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

  # --- Load ---

  block:
    let loadNative = KtgNative(
      name: "load",
      arity: 1,
      refinements: @[
        RefinementSpec(name: "eval", params: @[]),
        RefinementSpec(name: "freeze", params: @[]),
        RefinementSpec(name: "header", params: @[]),
        RefinementSpec(name: "fresh", params: @[])
      ],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = cast[Evaluator](ep)
        let path = case args[0].kind
          of vkString: args[0].strVal
          of vkFile: args[0].filePath
          else: raise KtgError(kind: "type", msg: "load expects string! or file!", data: nil)

        let content = readFile(path)
        let ast = parseSource(content)

        if "header" in eval.currentRefinements:
          # load/header — return just the header block (Kintsugi [...])
          if ast.len >= 2 and ast[0].kind == vkWord and ast[0].wordKind == wkWord and
             ast[0].wordName == "Kintsugi" and ast[1].kind == vkBlock:
            return ast[1]
          return ktgNone()

        if "eval" in eval.currentRefinements:
          # load/eval — evaluate in isolated context, return context!
          # load/eval/freeze — evaluate + freeze → object!
          let isoCtx = newContext(eval.global)
          discard eval.evalBlock(ast, isoCtx)
          if "freeze" in eval.currentRefinements:
            let obj = freeze(isoCtx)
            return KtgValue(kind: vkObject, obj: obj, line: 0)
          return KtgValue(kind: vkContext, ctx: isoCtx, line: 0)

        # plain load — return parsed values as a block
        return ktgBlock(ast)
    )
    ctx.set("load", KtgValue(kind: vkNative, nativeFn: loadNative, line: 0))

  # --- Save ---

  ctx.native("save", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let path = case args[0].kind
      of vkString: args[0].strVal
      of vkFile: args[0].filePath
      else: raise KtgError(kind: "type", msg: "save expects string! or file! as first arg", data: nil)

    proc serialize(val: KtgValue): string =
      case val.kind
      of vkString:
        "\"" & val.strVal.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
      of vkBlock:
        var s = "["
        for i, v in val.blockVals:
          if i > 0: s &= " "
          s &= serialize(v)
        s & "]"
      of vkContext:
        var s = ""
        var first = true
        for key, v in val.ctx.entries:
          if v.kind in {vkFunction, vkNative}: continue
          if key == "self": continue
          if not first: s &= "\n"
          s &= key & ": " & serialize(v)
          first = false
        s
      of vkObject:
        var s = ""
        var first = true
        for key, v in val.obj.entries:
          if v.kind in {vkFunction, vkNative}: continue
          if not first: s &= "\n"
          s &= key & ": " & serialize(v)
          first = false
        s
      of vkMap:
        var s = "make map! ["
        var first = true
        for key, v in val.mapEntries:
          if not first: s &= " "
          s &= key & ": " & serialize(v)
          first = false
        s & "]"
      of vkFunction, vkNative:
        ""  # skip
      else:
        $val

    writeFile(path, serialize(args[1]))
    ktgNone()
  )

  # --- Import (module loading) ---

  block:
    let importNative = KtgNative(
      name: "import",
      arity: 1,
      refinements: @[RefinementSpec(name: "fresh", params: @[])],
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = cast[Evaluator](ep)
        let rawPath = case args[0].kind
          of vkString: args[0].strVal
          of vkFile: args[0].filePath
          else: raise KtgError(kind: "type", msg: "import expects string! or file!", data: nil)

        # Resolve path relative to CWD
        let resolvedPath = if rawPath.isAbsolute: rawPath else: getCurrentDir() / rawPath

        # Check cache (skip if /fresh)
        if "fresh" notin eval.currentRefinements and resolvedPath in eval.moduleCache:
          return eval.moduleCache[resolvedPath]

        # Check for circular dependency
        if resolvedPath in eval.moduleLoading:
          raise KtgError(kind: "load",
            msg: "circular dependency detected: " & resolvedPath,
            data: nil)

        # Mark as loading
        eval.moduleLoading.incl(resolvedPath)

        try:
          let content = readFile(resolvedPath)
          var ast = parseSource(content)

          # Strip header: if AST starts with word "Kintsugi" followed by a block, skip those two
          if ast.len >= 2 and ast[0].kind == vkWord and ast[0].wordKind == wkWord and
             ast[0].wordName == "Kintsugi" and ast[1].kind == vkBlock:
            ast = ast[2..^1]

          # Evaluate in isolated context
          let isoCtx = newContext(eval.global)
          discard eval.evalBlock(ast, isoCtx)

          # Check for __exports
          var resultObj: KtgObject
          if isoCtx.has("__exports"):
            let exportsVal = isoCtx.get("__exports")
            if exportsVal.kind == vkBlock:
              var filtered = initOrderedTable[string, KtgValue]()
              for v in exportsVal.blockVals:
                if v.kind == vkWord:
                  let name = v.wordName
                  if isoCtx.has(name):
                    filtered[name] = isoCtx.get(name)
              resultObj = newObject(filtered)
            else:
              resultObj = freeze(isoCtx)
          else:
            resultObj = freeze(isoCtx)

          let res = KtgValue(kind: vkObject, obj: resultObj, line: 0)

          # Remove from loading, add to cache
          eval.moduleLoading.excl(resolvedPath)
          eval.moduleCache[resolvedPath] = res
          res
        except KtgError:
          eval.moduleLoading.excl(resolvedPath)
          raise
        except CatchableError:
          eval.moduleLoading.excl(resolvedPath)
          raise
    )
    ctx.set("import", KtgValue(kind: vkNative, nativeFn: importNative, line: 0))

  # --- Exports ---

  ctx.native("exports", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "exports expects block!", data: nil)
    eval.currentCtx.set("__exports", args[0])
    ktgNone()
  )

  # --- Bindings (compile-time dialect for foreign API declarations) ---

  ctx.native("bindings", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "bindings expects block!", data: nil)

    let blk = args[0].blockVals
    var pos = 0
    while pos < blk.len:
      # Expect: name (word) luaPath (string) kind (lit-word) [arity (integer)]
      if pos >= blk.len: break
      let nameVal = blk[pos]
      if nameVal.kind != vkWord or nameVal.wordKind != wkWord:
        pos += 1
        continue
      let name = nameVal.wordName
      pos += 1

      if pos >= blk.len: break
      let pathVal = blk[pos]
      if pathVal.kind != vkString:
        pos += 1
        continue
      pos += 1  # skip lua path string

      if pos >= blk.len: break
      let kindVal = blk[pos]
      if kindVal.kind != vkWord or kindVal.wordKind != wkLitWord:
        pos += 1
        continue
      let kindName = kindVal.wordName
      pos += 1

      case kindName
      of "call":
        var arity = 0
        if pos < blk.len and blk[pos].kind == vkInteger:
          arity = int(blk[pos].intVal)
          pos += 1
        # Register a pass-through native with the correct arity
        let capturedArity = arity
        let capturedName = name
        eval.currentCtx.set(name, KtgValue(kind: vkNative,
          nativeFn: KtgNative(name: capturedName, arity: capturedArity,
            fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
              # In interpreter mode, bindings are no-ops (foreign APIs not available)
              ktgNone()
          ), line: 0))
      of "const":
        # Register as a word bound to none (placeholder)
        eval.currentCtx.set(name, ktgNone())
      of "alias":
        # Register as none (the alias is only meaningful at compile time)
        eval.currentCtx.set(name, ktgNone())
      of "assign":
        # Register as a 1-arg native (callback assignment)
        let capturedName = name
        eval.currentCtx.set(name, KtgValue(kind: vkNative,
          nativeFn: KtgNative(name: capturedName, arity: 1,
            fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
              ktgNone()
          ), line: 0))
      else:
        discard

    ktgNone()
  )

  # --- emit (no-op at top level; functional inside #preprocess) ---
  ctx.native("emit", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgNone()
  )

  # --- raw (compile-time only, writes verbatim string to Lua output) ---
  ctx.native("raw", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgNone()
  )

  # --- system: platform, env ---
  block:
    let envCtx = newContext()
    for key, value in envPairs():
      envCtx.set(key, ktgString(value))

    let systemCtx = newContext()
    systemCtx.set("platform", ktgWord("script", wkLitWord))
    systemCtx.set("env", KtgValue(kind: vkContext, ctx: envCtx, line: 0))
    ctx.set("system", KtgValue(kind: vkContext, ctx: systemCtx, line: 0))

  # --- capture: declarative keyword extraction from blocks ---
  # capture data [@source @then @retries]
  #   @name    — greedy: captures everything from keyword to next keyword, strips self-references
  #   @name/N  — exact: captures N values after keyword
  # Returns a context with each keyword mapped to its captured value(s).
  # Missing keywords are none. Single greedy value unwraps (no block wrapper).

  ctx.native("capture", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "capture expects block! as first argument", data: nil)
    if args[1].kind != vkBlock:
      raise KtgError(kind: "type", msg: "capture expects block! as schema", data: nil)

    let data = args[0].blockVals
    let schema = args[1].blockVals

    type CaptureSpec = object
      keyword: string    ## the keyword to match (e.g., "source", "then", "field/required")
      bindName: string   ## context key (same as keyword but sanitized)
      exact: int         ## -1 = greedy, N = capture exactly N values

    # Parse schema: extract keyword names and modes
    var specs: seq[CaptureSpec] = @[]
    var allKeywords: seq[string] = @[]  # all keyword names for boundary detection

    for s in schema:
      if s.kind != vkWord or s.wordKind != wkMetaWord:
        continue
      let fullName = s.wordName
      # Split on / to check for /N suffix
      let parts = fullName.split('/')
      var keyword = fullName
      var exact = -1  # -1 = greedy

      # Check if last segment is a digit (exact count)
      if parts.len >= 2:
        var allDigits = true
        for c in parts[^1]:
          if c notin {'0'..'9'}:
            allDigits = false
            break
        if allDigits and parts[^1].len > 0:
          exact = parseInt(parts[^1])
          keyword = parts[0 .. ^2].join("/")

      specs.add(CaptureSpec(keyword: keyword, bindName: keyword, exact: exact))
      allKeywords.add(keyword)

    # Scan data block for keywords and capture values
    let resultCtx = newContext()

    # Initialize all captures to none
    for spec in specs:
      resultCtx.set(spec.bindName, ktgNone())

    # Walk data looking for keywords
    var pos = 0
    while pos < data.len:
      let val = data[pos]

      # Check if this value matches a schema keyword
      var matched = false
      for spec in specs:
        # Match: word with same name as keyword
        if val.kind == vkWord and val.wordKind == wkWord and val.wordName == spec.keyword:
          pos += 1  # skip the keyword word
          matched = true

          if spec.exact >= 0:
            # Exact mode: capture exactly N values
            var captured: seq[KtgValue] = @[]
            for j in 0 ..< spec.exact:
              if pos < data.len:
                captured.add(data[pos])
                pos += 1
            # If already has a value, this keyword repeats — append
            let existing = resultCtx.get(spec.bindName)
            if existing.kind == vkNone:
              if captured.len == 1:
                resultCtx.set(spec.bindName, captured[0])
              else:
                resultCtx.set(spec.bindName, ktgBlock(captured))
            else:
              # Repeating: wrap existing into block if needed, append
              var collected: seq[KtgValue] = @[]
              if existing.kind == vkBlock:
                for v in existing.blockVals:
                  collected.add(v)
              else:
                collected.add(existing)
              for v in captured:
                collected.add(v)
              resultCtx.set(spec.bindName, ktgBlock(collected))
          else:
            # Greedy mode: capture until next different keyword
            var captured: seq[KtgValue] = @[]
            while pos < data.len:
              let cur = data[pos]
              # Stop at a different keyword
              if cur.kind == vkWord and cur.wordKind == wkWord and
                 cur.wordName in allKeywords and cur.wordName != spec.keyword:
                break
              # Skip self-references (repeated keyword name)
              if cur.kind == vkWord and cur.wordKind == wkWord and
                 cur.wordName == spec.keyword:
                pos += 1
                continue
              captured.add(cur)
              pos += 1
            # Unwrap single value
            if captured.len == 0:
              resultCtx.set(spec.bindName, ktgNone())
            elif captured.len == 1:
              resultCtx.set(spec.bindName, captured[0])
            else:
              resultCtx.set(spec.bindName, ktgBlock(captured))
          break

      if not matched:
        pos += 1

    KtgValue(kind: vkContext, ctx: resultCtx, line: 0)
  )
