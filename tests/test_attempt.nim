import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerPrototypeDialect()
  eval.registerAttempt()
  eval

suite "attempt pipeline":
  test "basic pipeline":
    let eval = makeEval()
    let result = eval.evalString("""
      attempt [
        source ["  Hello, World  "]
        then   [trim it]
        then   [lowercase it]
      ]
    """)
    check $result == "hello, world"

  test "pipeline with split":
    let eval = makeEval()
    let result = eval.evalString("""
      attempt [
        source ["  Hello, World  "]
        then   [trim it]
        then   [lowercase it]
        then   [split it ", "]
      ]
    """)
    check result.kind == vkBlock
    check result.blockVals.len == 2
    check $result.blockVals[0] == "hello"
    check $result.blockVals[1] == "world"

  test "identity pipeline (source only)":
    let eval = makeEval()
    let result = eval.evalString("""
      attempt [
        source [42]
      ]
    """)
    check $result == "42"

  test "multiple then steps":
    let eval = makeEval()
    let result = eval.evalString("""
      attempt [
        source [10]
        then [it + 5]
        then [it * 2]
      ]
    """)
    check $result == "30"

suite "attempt reusable":
  test "reusable pipeline":
    let eval = makeEval()
    let result = eval.evalString("""
      clean: attempt [
        when [not empty? it]
        then [trim it]
        then [lowercase it]
      ]
      clean "  HELLO  "
    """)
    check $result == "hello"

  test "reusable pipeline guard fails":
    let eval = makeEval()
    let result = eval.evalString("""
      clean: attempt [
        when [not empty? it]
        then [trim it]
        then [lowercase it]
      ]
      clean ""
    """)
    check result.kind == vkNone

suite "attempt guards":
  test "when guard passes":
    let eval = makeEval()
    let result = eval.evalString("""
      attempt [
        source ["hello"]
        when [not empty? it]
        then [uppercase it]
      ]
    """)
    check $result == "HELLO"

  test "when guard fails":
    let eval = makeEval()
    let result = eval.evalString("""
      attempt [
        source [""]
        when [not empty? it]
        then [uppercase it]
      ]
    """)
    check result.kind == vkNone

suite "attempt error handling":
  test "fallback on error":
    let eval = makeEval()
    let result = eval.evalString("""
      attempt [
        source [first []]
        fallback ["oops"]
      ]
    """)
    check $result == "oops"

  test "catch specific error kind":
    let eval = makeEval()
    let result = eval.evalString("""
      attempt [
        source [first []]
        catch 'range ["caught range error"]
      ]
    """)
    check $result == "caught range error"
