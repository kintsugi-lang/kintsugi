import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/loop_dialect

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval

suite "compose":
  test "compose evaluates parens in block":
    let eval = makeEval()
    let r = eval.evalString("""
      x: 10
      @compose [a (x + 1) b]
    """)
    check $r == "[a 11 b]"

  test "compose leaves non-parens alone":
    let eval = makeEval()
    let r = eval.evalString("""@compose [1 "hello" [nested]]""")
    check $r == """[1 hello [nested]]"""

suite "preprocess":
  test "basic preprocess emits values":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        emit [x: 42]
      ]
      x
    """)
    check $r == "42"

  test "preprocess with platform check":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        if system/platform = 'script [
          emit [result: "on-script"]
        ]
      ]
      result
    """)
    check $r == "on-script"

  test "preprocess with no preprocess markers passes through":
    let eval = makeEval()
    let r = eval.evalString("1 + 2")
    check $r == "3"

  test "preprocess splices multiple emits":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        emit [a: 1]
        emit [b: 2]
      ]
      a + b
    """)
    check $r == "3"

  test "code after preprocess block evaluates normally":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        emit [base: 100]
      ]
      base + 5
    """)
    check $r == "105"
