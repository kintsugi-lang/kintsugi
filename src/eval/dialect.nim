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
    macros*: HashSet[string]   ## words declared with @template
    templates*: Table[string, TemplateDef]   ## @template body + mode, keyed by name
    typeDefs*: Table[string, TypeDef]    ## unified type registry; every @type and object registration writes here
    emitStack*: seq[ref seq[KtgValue]]   ## one queue per active @preprocess; @emit pushes to the top
    skipMode*: bool   ## true while short-circuiting `and`/`or` RHS: callables,
                      ## ops, dialects, and set-word binding all become no-ops.
                      ## Token consumption still advances correctly because
                      ## evalNext/callCallable walk the same arity spans.

  TemplateDef* = object
    params*: seq[ParamSpec]
    body*: seq[KtgValue]
    deep*: bool
    only*: bool

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

# Threaded evaluator handle for natives.
# On C/native backends, natives cast `ep: pointer` back to Evaluator directly.
# Nim's JS backend doesn't round-trip `cast[T](pointer)` reliably, so on JS
# the evaluator is stashed in a module-level var before each native call and
# read back from there. `getEvaluator` hides the difference.
var currentEvaluator*: Evaluator

proc getEvaluator*(ep: pointer): Evaluator {.inline.} =
  when defined(js):
    currentEvaluator
  else:
    cast[Evaluator](ep)
