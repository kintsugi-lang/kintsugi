import std/[strutils, tables, math, algorithm, sets, os]
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

  ctx.native("print", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    let s = $args[0]
    eval.output.add(s)
    echo s
    ktgNone()
  )

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

  ctx.native("append", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkBlock:
      args[0].blockVals.add(args[1])
      return args[0]
    if args[0].kind == vkString:
      raise KtgError(kind: "type", msg: "append does not work on strings — use join or rejoin", data: nil)
    raise KtgError(kind: "type", msg: "append expects block!, got " & typeName(args[0]), data: nil)
  )

  ctx.native("copy", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    case args[0].kind
    of vkBlock:
      ktgBlock(args[0].blockVals[0..^1])
    of vkString:
      ktgString(args[0].strVal)
    else:
      raise KtgError(kind: "type", msg: "copy not supported on " & typeName(args[0]), data: nil)
  )

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

  ctx.native("index?", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkBlock:
      for i, v in args[0].blockVals:
        if valuesEqual(v, args[1]): return ktgInt(int64(i + 1))
      return ktgNone()
    if args[0].kind == vkString and args[1].kind == vkString:
      let idx = args[0].strVal.find(args[1].strVal)
      if idx >= 0: return ktgInt(int64(idx + 1))
      return ktgNone()
    ktgNone()
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

  # override replace with 3-arg version
  ctx.native("replace", 3, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkString and args[1].kind == vkString and args[2].kind == vkString:
      return ktgString(args[0].strVal.replace(args[1].strVal, args[2].strVal))
    raise KtgError(kind: "type", msg: "replace expects string! string! string!", data: nil)
  )

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

  ctx.native("read-file", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let path = case args[0].kind
      of vkString: args[0].strVal
      of vkFile: args[0].filePath
      else:
        raise KtgError(kind: "type", msg: "read-file expects string! or file!", data: nil)
    if not fileExists(path):
      raise KtgError(kind: "io", msg: "file not found: " & path, data: args[0])
    ktgString(readFile(path))
  )

  ctx.native("write-file", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let path = case args[0].kind
      of vkString: args[0].strVal
      of vkFile: args[0].filePath
      else:
        raise KtgError(kind: "type", msg: "write-file expects string! or file!", data: nil)
    if args[1].kind != vkString:
      raise KtgError(kind: "type", msg: "write-file expects string! as content", data: nil)
    writeFile(path, args[1].strVal)
    ktgNone()
  )

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
        var r = eval.evalNext(args[0].blockVals, pos, eval.global)
        eval.applyInfix(r, args[0].blockVals, pos, eval.global)
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
      let ctxInner = newContext(eval.global)
      discard eval.evalBlock(args[0].blockVals, ctxInner)
      return KtgValue(kind: vkContext, ctx: ctxInner, line: 0)
    raise KtgError(kind: "type", msg: "context expects block!", data: nil)
  )

  ctx.native("freeze", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind == vkContext:
      return KtgValue(kind: vkObject, obj: freeze(args[0].ctx), line: 0)
    if args[0].kind == vkObject:
      return args[0]  # already frozen
    raise KtgError(kind: "type", msg: "freeze expects context!", data: nil)
  )

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
      # Refinement declaration: / followed by word (/ is parsed as vkOp)
      if s.kind == vkOp and s.opSymbol == "/":
        # Next token should be the refinement name
        if i + 1 < spec.len and spec[i + 1].kind == vkWord and spec[i + 1].wordKind == wkWord:
          i += 1
          let refName = spec[i].wordName
          refinements.add(RefinementSpec(name: refName, params: @[]))
          inRefinement = true
          i += 1
          continue
        else:
          i += 1
          continue
      if s.kind == vkWord and s.wordKind == wkWord:
        var pname = s.wordName
        var ptype = ""
        var elemType = ""
        var isOpt = false
        # check for type block
        if i + 1 < spec.len and spec[i + 1].kind == vkBlock:
          i += 1
          let typeBlock = spec[i].blockVals
          if typeBlock.len > 0:
            # Handle "opt type!" syntax
            if typeBlock[0].kind == vkWord and typeBlock[0].wordKind == wkWord and
               typeBlock[0].wordName == "opt" and typeBlock.len > 1:
              isOpt = true
              ptype = $typeBlock[1]
            # Handle typed blocks: [block! integer!] — container + element type
            elif typeBlock.len == 2 and typeBlock[0].kind == vkType and
                 typeBlock[0].typeName == "block!" and typeBlock[1].kind == vkType:
              ptype = "block!"
              elemType = typeBlock[1].typeName
            else:
              ptype = $typeBlock[0]
        if inRefinement:
          # This is a refinement parameter
          if refinements.len > 0:
            refinements[^1].params.add(ParamSpec(name: pname, typeName: ptype, elementType: elemType, isOpt: isOpt))
        else:
          params.add(ParamSpec(name: pname, typeName: ptype, elementType: elemType, isOpt: isOpt))
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
        ParamSpec(name: "handler", typeName: "", isOpt: false)
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
            # Call handler with kind, message, data
            try:
              var handlerArgs = @[errKind, errMsg, errData]
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

  # --- Set (destructuring) ---

  ctx.native("set", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "set expects [words] and value", data: nil)

    let names = args[0].blockVals
    let source = args[1]

    if source.kind == vkBlock:
      # positional destructuring
      for i, name in names:
        if name.kind == vkWord and i < source.blockVals.len:
          eval.global.set(name.wordName, source.blockVals[i])
    elif source.kind == vkContext:
      # named destructuring
      for name in names:
        if name.kind == vkWord and name.wordName in source.ctx.entries:
          eval.global.set(name.wordName, source.ctx.entries[name.wordName])
    elif source.kind == vkObject:
      # named destructuring from object
      for name in names:
        if name.kind == vkWord and name.wordName in source.obj.entries:
          eval.global.set(name.wordName, source.obj.entries[name.wordName])

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
      of vkFloat: return ktgMoney(int64(val.floatVal * 100.0 + 0.5))
      of vkString:
        try:
          let f = parseFloat(val.strVal)
          return ktgMoney(int64(f * 100.0 + 0.5))
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
        ParamSpec(name: "key-fn", typeName: "", isOpt: false)
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

  ctx.native("make", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    let typeArg = args[0]
    let specBlock = args[1]

    # make object!/context! from prototype + overrides
    if typeArg.kind == vkObject:
      if specBlock.kind != vkBlock:
        raise KtgError(kind: "type", msg: "make expects object! and block!", data: nil)
      let proto = typeArg.obj
      let ctxInner = newContext(eval.global)
      # copy prototype fields
      for key, val in proto.entries:
        if val.kind != vkFunction and val.kind != vkNative:
          ctxInner.set(key, val)
      # evaluate overrides
      discard eval.evalBlock(specBlock.blockVals, ctxInner)
      # bind self
      let res = KtgValue(kind: vkContext, ctx: ctxInner, line: 0)
      ctxInner.set("self", res)
      # copy methods
      for key, val in proto.entries:
        if val.kind == vkFunction or val.kind == vkNative:
          ctxInner.set(key, val)
      return res

    if typeArg.kind == vkContext:
      if specBlock.kind != vkBlock:
        raise KtgError(kind: "type", msg: "make expects context! and block!", data: nil)
      let proto = typeArg.ctx
      let ctxInner = newContext(eval.global)
      for key, val in proto.entries:
        ctxInner.set(key, val)
      discard eval.evalBlock(specBlock.blockVals, ctxInner)
      let res = KtgValue(kind: vkContext, ctx: ctxInner, line: 0)
      ctxInner.set("self", res)
      return res

    # make map! [key: val ...]
    if typeArg.kind == vkType and typeArg.typeName == "map!":
      if specBlock.kind != vkBlock:
        raise KtgError(kind: "type", msg: "make map! expects block!", data: nil)
      let ctxInner = newContext(eval.global)
      discard eval.evalBlock(specBlock.blockVals, ctxInner)
      var entries = initOrderedTable[string, KtgValue]()
      for key, val in ctxInner.entries:
        entries[key] = val
      return KtgValue(kind: vkMap, mapEntries: entries, line: 0)

    # make set! [values...]
    if typeArg.kind == vkType and typeArg.typeName == "set!":
      if specBlock.kind != vkBlock:
        raise KtgError(kind: "type", msg: "make set! expects block!", data: nil)
      # Evaluate the block to get values
      var members = initHashSet[string]()
      var pos = 0
      while pos < specBlock.blockVals.len:
        var v = eval.evalNext(specBlock.blockVals, pos, eval.currentCtx)
        eval.applyInfix(v, specBlock.blockVals, pos, eval.currentCtx)
        members.incl($v)
      return KtgValue(kind: vkSet, setMembers: members, line: 0)

    raise KtgError(kind: "type",
      msg: "make does not support " & $typeArg, data: nil)
  )

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

  ctx.native("load", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    let path = case args[0].kind
      of vkString: args[0].strVal
      of vkFile: args[0].filePath
      else: raise KtgError(kind: "type", msg: "load expects string! or file!", data: nil)

    let content = readFile(path)
    let ast = parseSource(content)

    if "eval" in eval.currentRefinements:
      # load/eval — evaluate in isolated context, freeze to object!
      let isoCtx = newContext(eval.global)
      discard eval.evalBlock(ast, isoCtx)
      let obj = freeze(isoCtx)
      return KtgValue(kind: vkObject, obj: obj, line: 0)

    if "freeze" in eval.currentRefinements:
      # load/freeze — parse as data, freeze to object!
      let isoCtx = newContext(eval.global)
      discard eval.evalBlock(ast, isoCtx)
      let obj = freeze(isoCtx)
      return KtgValue(kind: vkObject, obj: obj, line: 0)

    # plain load — return parsed values as a block
    return ktgBlock(ast)
  )

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
        var s = "["
        var first = true
        for key, v in val.ctx.entries:
          if v.kind in {vkFunction, vkNative}: continue
          if key == "self": continue
          if not first: s &= " "
          s &= key & ": " & serialize(v)
          first = false
        s & "]"
      of vkObject:
        var s = "["
        var first = true
        for key, v in val.obj.entries:
          if v.kind in {vkFunction, vkNative}: continue
          if not first: s &= " "
          s &= key & ": " & serialize(v)
          first = false
        s & "]"
      of vkMap:
        var s = "["
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

  # --- Require ---

  ctx.native("require", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    let rawPath = case args[0].kind
      of vkString: args[0].strVal
      of vkFile: args[0].filePath
      else: raise KtgError(kind: "type", msg: "require expects string! or file!", data: nil)

    # Resolve path relative to CWD
    let resolvedPath = if rawPath.isAbsolute: rawPath else: getCurrentDir() / rawPath

    # Check cache
    if resolvedPath in eval.moduleCache:
      return eval.moduleCache[resolvedPath]

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
    eval.moduleCache[resolvedPath] = res
    res
  )

  # --- Exports ---

  ctx.native("exports", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = cast[Evaluator](ep)
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "exports expects block!", data: nil)
    eval.currentCtx.set("__exports", args[0])
    ktgNone()
  )
