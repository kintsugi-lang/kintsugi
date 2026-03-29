import std/[tables, sets]
import ../core/types

type
  Evaluator* = ref object
    global*: KtgContext
    currentCtx*: KtgContext  ## current calling context for natives
    currentRefinements*: seq[string]  ## refinements for current native call
    output*: seq[string]
    callStack*: seq[StackFrame]
    dialects*: seq[Dialect]
    moduleCache*: Table[string, KtgValue]
    moduleLoading*: HashSet[string]
    globals*: HashSet[string]  ## words declared with @global

  Dialect* = ref object of RootObj
    name*: string
    vocabulary*: seq[string]

method interpret*(d: Dialect,
                  blk: seq[KtgValue],
                  eval: Evaluator,
                  ctx: KtgContext,
                  refinements: seq[string] = @[]): KtgValue {.base.} =
  raise KtgError(
    kind: "dialect",
    msg: "dialect '" & d.name & "' has no interpret method",
    data: nil
  )

proc isCallable*(val: KtgValue): bool =
  val.kind in {vkFunction, vkNative}

proc isInfix*(val: KtgValue): bool =
  val.kind == vkOp or
    (val.kind == vkWord and val.wordName in ["and", "or"])
