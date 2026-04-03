import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, parse_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerParse()
  eval

# ============================================================
# Feature 1: parse/ok? refinement
# ============================================================

suite "parse/ok? refinement":
  test "parse/ok? returns true on match":
    let eval = makeEval()
    check $eval.evalString("""@parse/ok? "hello" ["hello"]""") == "true"

  test "parse/ok? returns false on no match":
    let eval = makeEval()
    check $eval.evalString("""@parse/ok? "hello" ["world"]""") == "false"

  test "parse/ok? returns logic type":
    let eval = makeEval()
    let result = eval.evalString("""@parse/ok? "abc" ["abc"]""")
    check result.kind == vkLogic
    check result.boolVal == true

  test "parse without /ok still returns context":
    let eval = makeEval()
    let result = eval.evalString("""@parse "abc" ["abc"]""")
    check result.kind == vkContext

# ============================================================
# Feature 2: rethrow
# ============================================================

suite "rethrow":
  test "rethrow re-raises error from try result":
    let eval = makeEval()
    check $eval.evalString("""
      result: try [error 'bad "oops" none]
      outer: try [rethrow result]
      outer/ok
    """) == "false"

  test "rethrow preserves error kind":
    let eval = makeEval()
    check $eval.evalString("""
      result: try [error 'math "divide by zero" none]
      outer: try [rethrow result]
      outer/kind
    """) == "'math"

  test "rethrow preserves error message":
    let eval = makeEval()
    check $eval.evalString("""
      result: try [error 'math "divide by zero" none]
      outer: try [rethrow result]
      outer/message
    """) == "divide by zero"

# ============================================================
# Feature 3: freeze/deep
# ============================================================

suite "freeze/deep":
  test "freeze/deep recursively freezes nested contexts":
    let eval = makeEval()
    let result = eval.evalString("""
      inner: context [x: 1]
      outer: context [child: inner]
      frozen: freeze/deep outer
      type frozen/child
    """)
    check $result == "object!"

  test "regular freeze does not freeze nested contexts":
    let eval = makeEval()
    let result = eval.evalString("""
      inner: context [x: 1]
      outer: context [child: inner]
      frozen: freeze outer
      type frozen/child
    """)
    check $result == "context!"

  test "freeze/deep preserves values":
    let eval = makeEval()
    check $eval.evalString("""
      inner: context [val: 42]
      outer: context [nested: inner]
      frozen: freeze/deep outer
      frozen/nested/val
    """) == "42"

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
      length? first original
    """) == "2"

  test "shallow copy shares nested blocks":
    let eval = makeEval()
    check $eval.evalString("""
      original: [[1 2] [3 4]]
      cloned: copy original
      append first cloned 99
      length? first original
    """) == "3"

  test "copy/deep on context creates independent copy":
    let eval = makeEval()
    check $eval.evalString("""
      original: context [items: [1 2 3]]
      cloned: copy/deep original
      append cloned/items 99
      length? original/items
    """) == "3"

# ============================================================
# Feature 5: N M rule in parse
# ============================================================

suite "N M rule in parse":
  test "between N and M matches - exact range":
    let eval = makeEval()
    # 2 4 means between 2 and 4 repetitions
    check $eval.evalString("""@parse/ok? "aaa" [2 4 "a"]""") == "true"

  test "N M rule - minimum matches":
    let eval = makeEval()
    check $eval.evalString("""@parse/ok? "aa" [2 4 "a"]""") == "true"

  test "N M rule - maximum matches":
    let eval = makeEval()
    check $eval.evalString("""@parse/ok? "aaaa" [2 4 "a"]""") == "true"

  test "N M rule - too few matches":
    let eval = makeEval()
    check $eval.evalString("""@parse/ok? "a" [2 4 "a"]""") == "false"

  test "N M rule - exact N repetition still works":
    let eval = makeEval()
    check $eval.evalString("""@parse/ok? "aaa" [3 "a"]""") == "true"

  test "N M rule with char classes":
    let eval = makeEval()
    check $eval.evalString("""@parse/ok? "abc" [2 4 alpha]""") == "true"
