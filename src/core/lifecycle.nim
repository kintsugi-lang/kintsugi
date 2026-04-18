## @enter / @exit lifecycle hook partitioning.
##
## Both the interpreter (evaluator.nim:941-989) and the Lua emitter need
## to walk a block and separate `@enter [body]` hooks, `@exit [body]` hooks,
## and regular body values. This is the single shared implementation.
##
## Semantics:
## - `@enter [body]` runs once before the enclosing block's body executes.
## - `@exit [body]` runs after the body. In the interpreter it fires on
##   both normal return and exceptions (try/finally). The Lua emitter
##   compiles it as a plain serial splice — no pcall — because Lua has
##   no native finally and every existing usage in the repo (full-spec,
##   test_preprocess) only references enclosing-scope names from exit
##   blocks. If a real user need for exception-path @exit emerges, add
##   a `@exit!` variant rather than changing this default.

import ../core/types

type
  Lifecycle* = object
    enterBlocks*: seq[seq[KtgValue]]
    exitBlocks*: seq[seq[KtgValue]]
    body*: seq[KtgValue]

proc partitionLifecycle*(vals: seq[KtgValue]): Lifecycle =
  ## Extract @enter/@exit hook blocks out of a block's contents; what's
  ## left goes into `body` in original order. Returns empty enter/exit
  ## sequences when the block has no hooks (all other cases handled by
  ## caller treating `body` as the unchanged original).
  var i = 0
  while i < vals.len:
    if vals[i].kind == vkWord and vals[i].wordKind == wkMetaWord:
      if vals[i].wordName == "enter" and i + 1 < vals.len and
         vals[i + 1].kind == vkBlock:
        result.enterBlocks.add(vals[i + 1].blockVals)
        i += 2
        continue
      if vals[i].wordName == "exit" and i + 1 < vals.len and
         vals[i + 1].kind == vkBlock:
        result.exitBlocks.add(vals[i + 1].blockVals)
        i += 2
        continue
    result.body.add(vals[i])
    i += 1

proc hasHooks*(lc: Lifecycle): bool =
  lc.enterBlocks.len > 0 or lc.exitBlocks.len > 0
