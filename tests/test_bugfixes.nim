import std/[unittest, os]
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, object_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerObjectDialect()
  eval


suite "bugfix: context sees enclosing scope":
  test "context block can read variables from enclosing scope":
    let eval = makeEval()
    let result = eval.evalString("""
      outer: 42
      c: context [inner: outer]
      c/inner
    """)
    check $result == "42"

  test "context inside function sees function locals":
    let eval = makeEval()
    let result = eval.evalString("""
      f: function [x] [
        context [val: x]
      ]
      c: f 99
      c/val
    """)
    check $result == "99"


suite "bugfix: set destructures into current scope":
  test "set inside function does not leak to global":
    let eval = makeEval()
    let result = eval.evalString("""
      f: function [] [
        set [a b] [10 20]
        a + b
      ]
      f
    """)
    check $result == "30"

  test "set inside function with context destructuring":
    let eval = makeEval()
    let result = eval.evalString("""
      f: function [] [
        c: context [x: 5 y: 6]
        set [x y] c
        x + y
      ]
      f
    """)
    check $result == "11"


suite "bugfix: reduce evaluates in current scope":
  test "reduce inside function sees local variables":
    let eval = makeEval()
    let result = eval.evalString("""
      f: function [x] [
        reduce [x x + 1]
      ]
      f 10
    """)
    check $result == "[10 11]"


suite "bugfix: make validates required fields":
  test "make raises on missing required field":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        Person: object [
          field/required [name [string!]]
          field/required [age [integer!]]
        ]
        make Person [name: "Alice"]
      """)

  test "make succeeds with all required fields":
    let eval = makeEval()
    let result = eval.evalString("""
      Person: object [
        field/required [name [string!]]
        field/required [age [integer!]]
      ]
      p: make Person [name: "Alice" age: 30]
      p/name
    """)
    check $result == "Alice"


suite "bugfix: make type-checks overrides":
  test "make raises on wrong type for field":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        Person: object [
          field/required [name [string!]]
        ]
        make Person [name: 42]
      """)

  test "make accepts correct types":
    let eval = makeEval()
    let result = eval.evalString("""
      Person: object [
        field/required [name [string!]]
        field/optional [age [integer!] 0]
      ]
      p: make Person [name: "Bob" age: 25]
      p/age
    """)
    check $result == "25"


suite "bugfix: circular require detection":
  test "circular require raises load error":
    # Create two files that require each other
    let tmpDir = getTempDir() / "kintsugi_test_circular"
    createDir(tmpDir)
    let fileA = tmpDir / "a.ktg"
    let fileB = tmpDir / "b.ktg"
    writeFile(fileA, "b: require \"" & fileB & "\"")
    writeFile(fileB, "a: require \"" & fileA & "\"")

    let eval = makeEval()
    try:
      expect KtgError:
        discard eval.evalString("require \"" & fileA & "\"")
    finally:
      removeFile(fileA)
      removeFile(fileB)
      removeDir(tmpDir)
