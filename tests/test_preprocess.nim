import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/loop_dialect

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval

suite "preprocess":
  test "basic preprocess emits values":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        @emit [x: 42]
      ]
      x
    """)
    check $r == "42"

  test "preprocess with platform check":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        if system/platform = 'script [
          @emit [result: "on-script"]
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
        @emit [a: 1]
        @emit [b: 2]
      ]
      a + b
    """)
    check $r == "3"

  test "code after preprocess block evaluates normally":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        @emit [base: 100]
      ]
      base + 5
    """)
    check $r == "105"

suite "@emit":
  test "@emit splices a literal block like emit":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        @emit [x: 10]
      ]
      x
    """)
    check $r == "10"

  test "@emit auto-interpolates top-level parens":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        v: 42
        @emit [val: (v)]
      ]
      val
    """)
    check $r == "42"

  test "@emit auto-interpolates deep into nested blocks":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        v: 7
        @emit [outer: [(v) (v + 1)]]
      ]
      first outer
    """)
    check $r == "7"

  test "@emit splices block values (default compose semantics)":
    let eval = makeEval()
    let r = eval.evalString("""
      @preprocess [
        items: [1 2 3]
        @emit [result: [0 (items) 4]]
      ]
      result
    """)
    check $r == "[0 1 2 3 4]"

  test "@emit outside @preprocess raises":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("@emit [foo]")
