import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval

suite "match":
  test "literal match":
    let eval = makeEval()
    check $eval.evalString("""match 1 [[1] ["one"] [2] ["two"]]""") == "one"

  test "wildcard":
    let eval = makeEval()
    check $eval.evalString("""match 99 [[_] ["caught"]]""") == "caught"

  test "capture":
    let eval = makeEval()
    check $eval.evalString("""match 42 [[n] [n + 1]]""") == "43"

  test "guard":
    let eval = makeEval()
    check $eval.evalString("""match 25 [[n] when [n < 13] ["child"] [n] when [n < 65] ["adult"] [_] ["senior"]]""") == "adult"

  test "default":
    let eval = makeEval()
    check $eval.evalString("""match 99 [[1] ["one"] default: ["other"]]""") == "other"

  test "no match returns none":
    let eval = makeEval()
    check $eval.evalString("""match 99 [[1] ["one"] [2] ["two"]]""") == "none"

  test "type match":
    let eval = makeEval()
    check $eval.evalString("""match 42 [[integer!] ["int"] [string!] ["str"]]""") == "int"
    check $eval.evalString("""match "hi" [[integer!] ["int"] [string!] ["str"]]""") == "str"
