import ../core/types
import ../eval/[dialect, evaluator]

type
  LoopDialect* = ref object of Dialect

  LoopMode = enum
    lmInfinite   # loop [body]
    lmForIn      # for [vars] in series [body]
    lmFromTo     # for [vars] from N to M [body] or from N to M [body]

  LoopSpec = object
    mode: LoopMode
    vars: seq[string]
    series: KtgValue
    fromVal, toVal, stepVal: KtgValue
    guardBlock: seq[KtgValue]  # when [...] filter
    body: seq[KtgValue]

proc newLoopDialect*(): LoopDialect =
  LoopDialect(
    name: "loop",
    vocabulary: @["for", "in", "from", "to", "by", "when", "do", "it"]
  )

proc parseLoopSpec(blk: seq[KtgValue], eval: Evaluator, ctx: KtgContext): LoopSpec =
  var spec = LoopSpec(mode: lmInfinite)
  var pos = 0

  # check for 'for' keyword
  if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "for":
    pos += 1
    # variable binding block
    if pos < blk.len and blk[pos].kind == vkBlock:
      for v in blk[pos].blockVals:
        if v.kind == vkWord: spec.vars.add(v.wordName)
      pos += 1

    # 'in' or 'from'
    if pos < blk.len and blk[pos].kind == vkWord:
      case blk[pos].wordName
      of "in":
        spec.mode = lmForIn
        pos += 1
        # evaluate the series expression
        spec.series = eval.evalNext(blk, pos, ctx)
      of "from":
        spec.mode = lmFromTo
        pos += 1
        spec.fromVal = eval.evalNext(blk, pos, ctx)
        # expect 'to'
        if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "to":
          pos += 1
          spec.toVal = eval.evalNext(blk, pos, ctx)
        # optional 'by'
        if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "by":
          pos += 1
          spec.stepVal = eval.evalNext(blk, pos, ctx)
      else: discard

  elif pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "from":
    # from/to without explicit 'for' — uses 'it' as implicit var
    spec.mode = lmFromTo
    spec.vars = @["it"]
    pos += 1
    spec.fromVal = eval.evalNext(blk, pos, ctx)
    if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "to":
      pos += 1
      spec.toVal = eval.evalNext(blk, pos, ctx)
    if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "by":
      pos += 1
      spec.stepVal = eval.evalNext(blk, pos, ctx)

  # optional 'when' guard
  if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "when":
    pos += 1
    if pos < blk.len and blk[pos].kind == vkBlock:
      spec.guardBlock = blk[pos].blockVals
      pos += 1

  # 'do' before body block — required for for/in and from/to
  if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "do":
    pos += 1
  elif spec.mode != lmInfinite:
    raise KtgError(kind: "parse",
      msg: "loop body requires 'do' before the body block",
      data: nil)

  # body — remaining block
  if pos < blk.len and blk[pos].kind == vkBlock:
    spec.body = blk[pos].blockVals
  elif spec.mode == lmInfinite:
    # entire block is the body for infinite loops
    spec.body = blk

  spec


method interpret*(d: LoopDialect, blk: seq[KtgValue],
                  eval: Evaluator, ctx: KtgContext,
                  refinements: seq[string] = @[]): KtgValue =
  let spec = parseLoopSpec(blk, eval, ctx)

  let refinement = if refinements.len > 0: refinements[0] else: ""

  # For fold: first var is accumulator, second is iteration var
  # For partition: body is predicate, collect [truthy, falsy]
  var collected: seq[KtgValue] = @[]
  var accumulator: KtgValue = nil
  var trueItems: seq[KtgValue] = @[]
  var falseItems: seq[KtgValue] = @[]

  template iterateBody(loopCtx: KtgContext, iterVal: KtgValue) =
    case refinement
    of "fold":
      if spec.vars.len >= 2:
        if accumulator == nil:
          # First iteration: accumulator = iteration value, skip body
          accumulator = iterVal
        else:
          loopCtx.set(spec.vars[0], accumulator)
          loopCtx.set(spec.vars[1], iterVal)
          accumulator = eval.evalBlock(spec.body, loopCtx)
      else:
        # single var fold: acc is first result
        if accumulator == nil:
          accumulator = iterVal
        else:
          loopCtx.set(spec.vars[0], accumulator)
          accumulator = eval.evalBlock(spec.body, loopCtx)
    of "partition":
      loopCtx.set(spec.vars[0], iterVal)
      let predResult = eval.evalBlock(spec.body, loopCtx)
      if isTruthy(predResult):
        trueItems.add(iterVal)
      else:
        falseItems.add(iterVal)
    of "collect":
      if spec.body.len > 0:
        if spec.vars.len > 0:
          loopCtx.set(spec.vars[0], iterVal)
        let bodyResult = eval.evalBlock(spec.body, loopCtx)
        collected.add(bodyResult)
      else:
        collected.add(iterVal)
    else:
      if spec.vars.len > 0:
        loopCtx.set(spec.vars[0], iterVal)
      discard eval.evalBlock(spec.body, loopCtx)

  case spec.mode

  of lmInfinite:
    while true:
      try:
        discard eval.evalBlock(spec.body, ctx)
      except BreakSignal:
        break

  of lmForIn:
    if spec.series == nil or spec.series.kind != vkBlock:
      raise KtgError(kind: "type", msg: "loop: 'in' expects a block!", data: nil)
    for item in spec.series.blockVals:
      let loopCtx = ctx.child
      # guard
      if spec.vars.len > 0 and refinement notin ["fold"]:
        loopCtx.set(spec.vars[0], item)
      if spec.guardBlock.len > 0:
        let guardResult = eval.evalBlock(spec.guardBlock, loopCtx)
        if not isTruthy(guardResult): continue
      try:
        iterateBody(loopCtx, item)
      except BreakSignal:
        break

  of lmFromTo:
    if spec.fromVal == nil or spec.toVal == nil:
      raise KtgError(kind: "type", msg: "loop: from/to requires integer values", data: nil)
    let fromI = if spec.fromVal.kind == vkInteger: spec.fromVal.intVal else: 0'i64
    let toI = if spec.toVal.kind == vkInteger: spec.toVal.intVal else: 0'i64
    var step = if spec.stepVal != nil and spec.stepVal.kind == vkInteger:
                 spec.stepVal.intVal
               else:
                 if toI >= fromI: 1'i64 else: -1'i64

    if step == 0:
      raise KtgError(kind: "loop", msg: "loop step cannot be zero", data: nil)

    var i = fromI
    while (step > 0 and i <= toI) or (step < 0 and i >= toI):
      let loopCtx = ctx.child
      let iterVal = ktgInt(i)
      # guard — set var for guard evaluation in non-fold modes
      if spec.vars.len > 0 and refinement notin ["fold"]:
        loopCtx.set(spec.vars[0], iterVal)
      if spec.guardBlock.len > 0:
        let guardResult = eval.evalBlock(spec.guardBlock, loopCtx)
        if not isTruthy(guardResult):
          i += step
          continue
      try:
        iterateBody(loopCtx, iterVal)
      except BreakSignal:
        break
      i += step

  case refinement
  of "collect": return ktgBlock(collected)
  of "fold": return if accumulator != nil: accumulator else: ktgNone()
  of "partition": return ktgBlock(@[ktgBlock(trueItems), ktgBlock(falseItems)])
  else: return ktgNone()
