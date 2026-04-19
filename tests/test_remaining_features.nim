import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval


# ============================================================
# Feature 2: re-raising via error with captured kind/data
# (rethrow was removed; users pass through error kind data)
# ============================================================

suite "re-raise via error":
  test "re-raising produces failure result":
    let eval = makeEval()
    check $eval.evalString("""
      result: try [error 'bad "oops"]
      outer: try [error result/kind result/data]
      none? outer/kind
    """) == "false"

  test "re-raised kind is preserved":
    let eval = makeEval()
    check $eval.evalString("""
      result: try [error 'math "divide by zero"]
      outer: try [error result/kind result/data]
      outer/kind
    """) == "math"

  test "re-raised payload is preserved":
    let eval = makeEval()
    check $eval.evalString("""
      result: try [error 'math "divide by zero"]
      outer: try [error result/kind result/data]
      outer/data
    """) == "divide by zero"

# ============================================================
# Feature 4: copy/deep
# ============================================================

suite "copy/deep":
  test "copy/deep creates independent nested blocks":
    let eval = makeEval()
    check $eval.evalString("""
      original: [[1 2] [3 4]]
      cloned: copy/deep original
      append first cloned 99
      length first original
    """) == "2"

  test "shallow copy shares nested blocks":
    let eval = makeEval()
    check $eval.evalString("""
      original: [[1 2] [3 4]]
      cloned: copy original
      append first cloned 99
      length first original
    """) == "3"

  test "copy/deep on context creates independent copy":
    let eval = makeEval()
    check $eval.evalString("""
      original: context [items: [1 2 3]]
      cloned: copy/deep original
      append cloned/items 99
      length original/items
    """) == "3"
