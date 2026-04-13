import ../core/types
import ../eval/[dialect, evaluator]

## Attempt dialect — resilient pipelines with error handling.
##
## `attempt [pipeline]` — evaluates a pipeline of steps.
##
## Keywords:
##   source [expr]       — initial value (evaluated)
##   then   [expr]       — transform step; `it` = previous result
##   when   [expr]       — guard; short-circuits to none if falsy
##   catch  'kind [expr] — error handler for a specific error kind
##   fallback expr       — last-resort value on any unhandled error
##   retries N           — retry the source N times on error
##
## If `source` is present: evaluate source, run pipeline, return result.
## If no `source`: return a KtgFunction that takes 1 arg (bound as `it`).

type
  StepKind = enum
    skSource
    skThen
    skWhen
    skOn
    skFallback
    skRetries

  PipelineStep = object
    case kind: StepKind
    of skSource:
      sourceBody: seq[KtgValue]
    of skThen:
      thenBody: seq[KtgValue]
    of skWhen:
      whenBody: seq[KtgValue]
    of skOn:
      onKind: string
      onBody: seq[KtgValue]
    of skFallback:
      fallbackBody: seq[KtgValue]
    of skRetries:
      retryCount: int64


proc parsePipeline(blk: seq[KtgValue]): seq[PipelineStep] =
  ## Parse the pipeline block as inert data, scanning for keywords.
  var steps: seq[PipelineStep] = @[]
  var pos = 0

  while pos < blk.len:
    let current = blk[pos]

    if current.kind == vkWord and current.wordKind == wkWord:
      case current.wordName

      of "source":
        pos += 1
        if pos < blk.len and blk[pos].kind == vkBlock:
          steps.add(PipelineStep(kind: skSource, sourceBody: blk[pos].blockVals))
          pos += 1
        else:
          raise KtgError(kind: "attempt",
            msg: "source expects a block", data: nil)

      of "then":
        pos += 1
        if pos < blk.len and blk[pos].kind == vkBlock:
          steps.add(PipelineStep(kind: skThen, thenBody: blk[pos].blockVals))
          pos += 1
        else:
          raise KtgError(kind: "attempt",
            msg: "then expects a block", data: nil)

      of "when":
        pos += 1
        if pos < blk.len and blk[pos].kind == vkBlock:
          steps.add(PipelineStep(kind: skWhen, whenBody: blk[pos].blockVals))
          pos += 1
        else:
          raise KtgError(kind: "attempt",
            msg: "when expects a block", data: nil)

      of "catch":
        pos += 1
        # Expect a lit-word for the error kind
        if pos < blk.len and blk[pos].kind == vkWord and
           blk[pos].wordKind == wkLitWord:
          let errorKind = blk[pos].wordName
          pos += 1
          if pos < blk.len and blk[pos].kind == vkBlock:
            steps.add(PipelineStep(kind: skOn, onKind: errorKind,
                                   onBody: blk[pos].blockVals))
            pos += 1
          else:
            raise KtgError(kind: "attempt",
              msg: "catch '" & errorKind & " expects a handler block", data: nil)
        else:
          raise KtgError(kind: "attempt",
            msg: "catch expects a lit-word error kind (e.g., 'type)", data: nil)

      of "fallback":
        pos += 1
        if pos < blk.len and blk[pos].kind == vkBlock:
          steps.add(PipelineStep(kind: skFallback,
                                 fallbackBody: blk[pos].blockVals))
          pos += 1
        else:
          raise KtgError(kind: "attempt",
            msg: "fallback expects a block", data: nil)

      of "retries":
        pos += 1
        if pos < blk.len and blk[pos].kind == vkInteger:
          steps.add(PipelineStep(kind: skRetries,
                                 retryCount: blk[pos].intVal))
          pos += 1
        else:
          raise KtgError(kind: "attempt",
            msg: "retries expects an integer", data: nil)

      else:
        raise KtgError(kind: "attempt",
          msg: "unknown pipeline keyword: " & current.wordName, data: nil)
    else:
      raise KtgError(kind: "attempt",
        msg: "expected pipeline keyword, got " & typeName(current), data: nil)

  steps


proc runPipeline(eval: Evaluator, steps: seq[PipelineStep],
                 initialIt: KtgValue, ctx: KtgContext): KtgValue =
  ## Execute a parsed pipeline with an initial `it` value.
  ## Returns the final result or none on guard failure.
  var current = initialIt

  # Collect error handlers and fallback from steps
  var errorHandlers: seq[(string, seq[KtgValue])] = @[]
  var fallbackBody: seq[KtgValue] = @[]

  for step in steps:
    if step.kind == skOn:
      errorHandlers.add((step.onKind, step.onBody))
    elif step.kind == skFallback:
      fallbackBody = step.fallbackBody

  # Run through the pipeline steps
  for step in steps:
    case step.kind

    of skSource:
      # Source is already handled before calling runPipeline
      discard

    of skThen:
      let stepCtx = ctx.child
      stepCtx.set("it", current)
      try:
        current = eval.evalBlock(step.thenBody, stepCtx)
      except CatchableError:
        let exc = getCurrentException()
        if exc of KtgError:
          let e = KtgError(exc)
          # Check error handlers
          var handled = false
          for (kind, body) in errorHandlers:
            if kind == e.kind:
              let handlerCtx = ctx.child
              handlerCtx.set("it", current)
              handlerCtx.set("error", ktgString(e.msg))
              current = eval.evalBlock(body, handlerCtx)
              handled = true
              break
          if not handled:
            if fallbackBody.len > 0:
              let fbCtx = ctx.child
              fbCtx.set("it", current)
              fbCtx.set("error", ktgString(e.msg))
              current = eval.evalBlock(fallbackBody, fbCtx)
            else:
              raise
        else:
          raise

    of skWhen:
      let stepCtx = ctx.child
      stepCtx.set("it", current)
      let guardResult = eval.evalBlock(step.whenBody, stepCtx)
      if not isTruthy(guardResult):
        return ktgNone()

    of skOn, skFallback, skRetries:
      # These are metadata steps, handled elsewhere
      discard

  current


proc registerAttempt*(eval: Evaluator) =
  ## Register `attempt` as a 1-arity native that takes a pipeline block.
  let ctx = eval.global

  ctx.set("attempt", KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: "attempt", arity: 1, fn: proc(
        args: seq[KtgValue], ep: pointer): KtgValue =
      let eval = getEvaluator(ep)
      let pipeline = args[0]

      if pipeline.kind != vkBlock:
        raise KtgError(kind: "type",
          msg: "attempt expects a pipeline block",
          data: pipeline)

      let steps = parsePipeline(pipeline.blockVals)

      # Determine retry count
      var retryCount: int64 = 0
      for step in steps:
        if step.kind == skRetries:
          retryCount = step.retryCount
      if retryCount < 0:
        raise KtgError(kind: "attempt", msg: "retries must be non-negative", data: nil)

      # Check if there is a source step
      var hasSource = false
      var sourceBody: seq[KtgValue] = @[]
      for step in steps:
        if step.kind == skSource:
          hasSource = true
          sourceBody = step.sourceBody
          break

      if hasSource:
        # Immediate execution mode: evaluate source, run pipeline
        var attempts = retryCount + 1  # retries + initial attempt

        for attempt in 1 .. attempts:
          try:
            let sourceVal = eval.evalBlock(sourceBody, eval.currentCtx)
            return runPipeline(eval, steps, sourceVal, eval.currentCtx)
          except CatchableError:
            let exc = getCurrentException()
            if exc of KtgError:
              let e = KtgError(exc)
              if attempt < attempts:
                continue  # retry
              # Out of retries — check on handlers first
              for step in steps:
                if step.kind == skOn and step.onKind == e.kind:
                  let handlerCtx = eval.currentCtx.child
                  handlerCtx.set("error", ktgString(e.msg))
                  return eval.evalBlock(step.onBody, handlerCtx)
              # Then check fallback
              var fallbackBody: seq[KtgValue] = @[]
              for step in steps:
                if step.kind == skFallback:
                  fallbackBody = step.fallbackBody
                  break
              if fallbackBody.len > 0:
                let fbCtx = eval.currentCtx.child
                fbCtx.set("error", ktgString(e.msg))
                return eval.evalBlock(fallbackBody, fbCtx)
              raise
            else:
              raise

        # Should not reach here, but just in case
        return ktgNone()
      else:
        # No source — return a reusable pipeline function.
        # Capture the steps for the closure.
        let capturedSteps = steps
        let capturedCtx = eval.currentCtx

        # We return a native that wraps the pipeline execution,
        # since we need to call runPipeline with captured steps.
        result = KtgValue(kind: vkNative,
          nativeFn: KtgNative(name: "attempt-pipeline", arity: 1, fn: proc(
              innerArgs: seq[KtgValue], innerEp: pointer): KtgValue =
            let innerEval = cast[Evaluator](innerEp)
            let inputVal = innerArgs[0]
            runPipeline(innerEval, capturedSteps, inputVal, capturedCtx)
          ),
          line: 0)
    ),
    line: 0))
