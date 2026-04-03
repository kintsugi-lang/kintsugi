import std/[math, random]
import ../core/types
import dialect

proc native(ctx: KtgContext, name: string, arity: int, fn: NativeFnProc) =
  ctx.set(name, KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: name, arity: arity, fn: fn),
    line: 0))

proc registerMathNatives*(eval: Evaluator) =
  let ctx = eval.global

  # Helper to extract float from number arg
  template numArg(a: KtgValue, fname: string): float64 =
    case a.kind
    of vkInteger: float64(a.intVal)
    of vkFloat: a.floatVal
    else: raise KtgError(kind: "type", msg: fname & " expects number!", data: nil)

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
      return ktgInt(int64(trunc(v)))
    elif "up" in eval.currentRefinements:
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

  block:
    randomize()
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

        if "range" in eval.currentRefinements:
          let lo = numArg(args[0], "random/range")
          let hi = numArg(args[1], "random/range")
          if "int" in eval.currentRefinements:
            return ktgInt(int64(rand(int(hi) - int(lo)) + int(lo)))
          return ktgFloat(lo + rand(hi - lo))

        if "int" in eval.currentRefinements:
          let n = case args[0].kind
            of vkInteger: int(args[0].intVal)
            else: raise KtgError(kind: "type", msg: "random/int expects integer!", data: nil)
          return ktgInt(int64(rand(n - 1)))

        let n = numArg(args[0], "random")
        ktgFloat(rand(n))
    )
    ctx.set("random", KtgValue(kind: vkNative, nativeFn: randomNative, line: 0))
