import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/loop_dialect

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval

suite "user function refinements":
  test "basic boolean refinement":
    let eval = makeEval()
    discard eval.evalString("""
      greet: function [name [string!] / loud] [
        message: join "Hello, " name
        if loud [message: uppercase message]
        message
      ]
    """)
    check $eval.evalString("""greet "world" """) == "Hello, world"
    check $eval.evalString("""greet/loud "world" """) == "HELLO, WORLD"

  test "refinement with parameter":
    let eval = makeEval()
    discard eval.evalString("""
      format: function [val / pad size [integer!]] [
        either pad [
          rejoin [val " (padded to " size ")"]
        ] [
          to string! val
        ]
      ]
    """)
    check $eval.evalString("format 42") == "42"
    check $eval.evalString("format/pad 42 10") == "42 (padded to 10)"

  test "multiple refinements":
    let eval = makeEval()
    discard eval.evalString("""
      say: function [msg [string!] / loud / prefix tag [string!]] [
        result: msg
        if prefix [result: join tag result]
        if loud [result: uppercase result]
        result
      ]
    """)
    check $eval.evalString("""say "hello" """) == "hello"
    check $eval.evalString("""say/loud "hello" """) == "HELLO"
    check $eval.evalString("""say/prefix "hello" "[!] " """) == "[!] hello"

  test "inactive refinement defaults to false":
    let eval = makeEval()
    discard eval.evalString("""
      check-ref: function [/ active] [
        active
      ]
    """)
    check $eval.evalString("check-ref") == "false"
    check $eval.evalString("check-ref/active") == "true"

  test "refinement param defaults to none when inactive":
    let eval = makeEval()
    discard eval.evalString("""
      check-param: function [/ with name [string!]] [
        either with [name] [none]
      ]
    """)
    check $eval.evalString("check-param") == "none"
    check $eval.evalString("""check-param/with "Ray" """) == "Ray"
