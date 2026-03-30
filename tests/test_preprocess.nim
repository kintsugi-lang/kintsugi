import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/loop_dialect

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval

suite "bind":
  test "bind block to context, do evaluates in that context":
    let eval = makeEval()
    let r = eval.evalString("""
      my-ctx: context [x: 42]
      code: [x]
      bind code my-ctx
      do code
    """)
    check $r == "42"

  test "bind returns the block":
    let eval = makeEval()
    let r = eval.evalString("""
      c: context [a: 10]
      b: bind [a] c
      block? b
    """)
    check $r == "true"

  test "bind error on non-block":
    let eval = makeEval()
    discard eval.evalString("""r: try [bind 42 context []]""")
    check $eval.evalString("r/ok") == "false"

  test "bind error on non-context":
    let eval = makeEval()
    discard eval.evalString("""r: try [bind [x] 42]""")
    check $eval.evalString("r/ok") == "false"

suite "lifecycle hooks":
  test "@enter runs before body":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      do [
        @enter [log: "entered"]
        result: log
      ]
    """)
    check $eval.evalString("result") == "entered"

  test "@exit runs after body":
    let eval = makeEval()
    discard eval.evalString("""
      do [
        @exit [cleanup: "done"]
        x: 1
      ]
    """)
    check $eval.evalString("cleanup") == "done"

  test "@enter and @exit together":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      order: []
      do [
        @enter [append order "enter"]
        @exit [append order "exit"]
        append order "body"
      ]
    """)
    check $eval.evalString("first order") == "enter"
    check $eval.evalString("pick order 2") == "body"
    check $eval.evalString("last order") == "exit"

  test "multiple @enter hooks run in order":
    let eval = makeEval()
    discard eval.evalString("""
      order: []
      do [
        @enter [append order "a"]
        @enter [append order "b"]
        append order "body"
      ]
    """)
    check $eval.evalString("first order") == "a"
    check $eval.evalString("pick order 2") == "b"
    check $eval.evalString("last order") == "body"

  test "@exit runs even if body has no hooks otherwise":
    let eval = makeEval()
    discard eval.evalString("""
      cleaned: false
      do [
        @exit [cleaned: true]
        x: 42
      ]
    """)
    check $eval.evalString("cleaned") == "true"

suite "compose":
  test "compose evaluates parens in block":
    let eval = makeEval()
    let r = eval.evalString("""
      x: 10
      compose [a (x + 1) b]
    """)
    check $r == "[a 11 b]"

  test "compose leaves non-parens alone":
    let eval = makeEval()
    let r = eval.evalString("""compose [1 "hello" [nested]]""")
    check $r == """[1 hello [nested]]"""

suite "preprocess":
  test "basic preprocess emits values":
    let eval = makeEval()
    let r = eval.evalString("""
      #preprocess [
        emit [x: 42]
      ]
      x
    """)
    check $r == "42"

  test "preprocess with platform check":
    let eval = makeEval()
    let r = eval.evalString("""
      #preprocess [
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
      #preprocess [
        emit [a: 1]
        emit [b: 2]
      ]
      a + b
    """)
    check $r == "3"

  test "code after preprocess block evaluates normally":
    let eval = makeEval()
    let r = eval.evalString("""
      #preprocess [
        emit [base: 100]
      ]
      base + 5
    """)
    check $r == "105"
