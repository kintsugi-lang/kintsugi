## Tests for stdlib modules: collections, math, string

import unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerPrototypeDialect()
  eval.registerAttempt()
  eval.registerParse()
  eval

proc evalStr(src: string): KtgValue =
  let eval = makeEval()
  eval.evalString(src)

# ============================================================
# Collections
# ============================================================

suite "collections: range":
  test "basic range":
    let r = evalStr("c: import %lib/collections.ktg c/range 1 5")
    check r.blockVals.len == 5
    check r.blockVals[0].intVal == 1
    check r.blockVals[4].intVal == 5

  test "range with step":
    let r = evalStr("c: import %lib/collections.ktg c/range/by 0 10 2")
    check r.blockVals.len == 6

suite "collections: take/drop":
  test "take":
    let r = evalStr("c: import %lib/collections.ktg c/take [1 2 3 4 5] 3")
    check r.blockVals.len == 3

  test "drop":
    let r = evalStr("c: import %lib/collections.ktg c/drop [1 2 3 4 5] 2")
    check r.blockVals.len == 3
    check r.blockVals[0].intVal == 3

suite "collections: partition":
  test "chunk by size":
    let r = evalStr("c: import %lib/collections.ktg c/partition [1 2 3 4 5 6 7] 3")
    check r.blockVals.len == 3
    check r.blockVals[0].blockVals.len == 3
    check r.blockVals[2].blockVals.len == 1

  test "chunk fresh each call":
    let eval = makeEval()
    discard eval.evalString("c: import %lib/collections.ktg")
    let r1 = eval.evalString("c/partition [1 2 3 4] 2")
    let r2 = eval.evalString("c/partition [5 6 7 8 9] 3")
    check r1.blockVals.len == 2
    check r2.blockVals.len == 2

suite "collections: unique":
  test "removes duplicates":
    let r = evalStr("c: import %lib/collections.ktg c/unique [1 2 1 3 2 4]")
    check r.blockVals.len == 4

suite "collections: zip":
  test "basic zip":
    let r = evalStr("c: import %lib/collections.ktg c/zip [1 2 3] [\"a\" \"b\" \"c\"]")
    check r.blockVals.len == 3
    check r.blockVals[0].kind == vkBlock
    check r.blockVals[0].blockVals[0].intVal == 1

suite "collections: rotate":
  test "rotate block left":
    let r = evalStr("c: import %lib/collections.ktg c/rotate [1 2 3 4 5] 2")
    check r.blockVals[0].intVal == 3
    check r.blockVals[4].intVal == 2

  test "rotate block right":
    let r = evalStr("c: import %lib/collections.ktg c/rotate [1 2 3 4 5] -1")
    check r.blockVals[0].intVal == 5

  test "rotate pair (2D)":
    let r = evalStr("c: import %lib/collections.ktg c/rotate 10x0 pi")
    check r.kind == vkPair
    # 10x0 rotated by pi radians ≈ -10x0
    check r.px == -10

suite "collections: choice":
  test "choice picks from block":
    let r = evalStr("random/seed 42 c: import %lib/collections.ktg c/choice [1 2 3 4 5]")
    check r.kind == vkInteger

suite "collections: flatten":
  test "one level":
    let r = evalStr("c: import %lib/collections.ktg c/flatten [[1 2] [3 4] [5]]")
    check r.blockVals.len == 5

  test "deep":
    let r = evalStr("c: import %lib/collections.ktg c/flatten/deep [[[1] [2]] [[3]]]")
    check r.blockVals.len == 3

suite "collections: interleave":
  test "basic":
    let r = evalStr("c: import %lib/collections.ktg c/interleave [1 2 3] [\"a\" \"b\" \"c\"]")
    check r.blockVals.len == 6

suite "collections: repeat":
  test "repeat value":
    check evalStr("c: import %lib/collections.ktg c/repeat 0 4").blockVals.len == 4

  test "repeat string":
    check evalStr("c: import %lib/collections.ktg c/repeat \"ha\" 3").strVal == "hahaha"

# ============================================================
# find/where (native)
# ============================================================

suite "find/where":
  test "finds first match":
    let r = evalStr("find/where [1 2 3 4] function [x] [x > 2]")
    check r.intVal == 3

  test "no match returns none":
    let r = evalStr("find/where [1 2 3] function [x] [x > 10]")
    check r.kind == vkNone

  test "find still works normally":
    check evalStr("find [10 20 30] 20").intVal == 2
    check evalStr("""find "hello" "ell" """).intVal == 2

# ============================================================
# Math
# ============================================================

suite "math: clamp/lerp/approach":
  test "clamp":
    check evalStr("m: import %lib/math.ktg m/clamp 15 0 10").intVal == 10

  test "lerp":
    check evalStr("m: import %lib/math.ktg m/lerp 0 100 0.5").floatVal == 50.0

  test "inverse-lerp":
    check evalStr("m: import %lib/math.ktg m/inverse-lerp 0 100 25").floatVal == 0.25

  test "approach":
    check evalStr("m: import %lib/math.ktg m/approach 10 0 3").intVal == 7

suite "math: easing":
  test "ease-in":
    check evalStr("m: import %lib/math.ktg m/ease 0.0").floatVal == 0.0
    check evalStr("m: import %lib/math.ktg m/ease 1.0").floatVal == 1.0

  test "ease-out":
    check evalStr("m: import %lib/math.ktg m/ease/out 0.5").floatVal == 0.75

  test "ease-in-out":
    check evalStr("m: import %lib/math.ktg m/ease/in/out 0.0").floatVal == 0.0

suite "math: distance":
  test "euclidean":
    check evalStr("m: import %lib/math.ktg m/distance 0x0 3x4").floatVal == 5.0

  test "manhattan":
    check evalStr("m: import %lib/math.ktg m/distance/manhattan 0x0 3x4").intVal == 7

  test "chebyshev":
    check evalStr("m: import %lib/math.ktg m/distance/chebyshev 0x0 3x4").intVal == 4

suite "math: grid":
  test "grid-index":
    check evalStr("m: import %lib/math.ktg m/grid-index 3x2 5").intVal == 8

  test "grid-pos":
    let r = evalStr("m: import %lib/math.ktg m/grid-pos 8 5")
    check r.px == 3
    check r.py == 2

suite "math: rect":
  test "point in rect":
    check evalStr("m: import %lib/math.ktg m/point-in-rect? 5 5 0 0 10 10").boolVal == true

  test "point outside rect":
    check evalStr("m: import %lib/math.ktg m/point-in-rect? 15 5 0 0 10 10").boolVal == false

  test "rects overlap":
    check evalStr("m: import %lib/math.ktg m/rects-overlap? 0 0 10 10 5 5 10 10").boolVal == true

  test "rects don't overlap":
    check evalStr("m: import %lib/math.ktg m/rects-overlap? 0 0 5 5 10 10 5 5").boolVal == false

suite "math: sign":
  test "positive":
    check evalStr("m: import %lib/math.ktg m/sign 5").intVal == 1
  test "negative":
    check evalStr("m: import %lib/math.ktg m/sign -3").intVal == -1
  test "zero":
    check evalStr("m: import %lib/math.ktg m/sign 0").intVal == 0

# ============================================================
# Pad (native)
# ============================================================

suite "pad":
  test "pad string left (default)":
    check evalStr("pad \"42\" 5 \"0\"").strVal == "00042"
  test "pad string right":
    check evalStr("pad/right \"42\" 5 \"0\"").strVal == "42000"
  test "pad block left (default)":
    let r = evalStr("pad [1 2] 5 0")
    check r.blockVals.len == 5
    check r.blockVals[0].intVal == 0
    check r.blockVals[3].intVal == 1
  test "pad block right":
    let r = evalStr("pad/right [1 2] 5 0")
    check r.blockVals.len == 5
    check r.blockVals[0].intVal == 1
    check r.blockVals[4].intVal == 0

# ============================================================
# Pair/tuple path access
# ============================================================

suite "pair path access":
  test "pair/x":
    check evalStr("p: 3x4 p/x").intVal == 3
  test "pair/y":
    check evalStr("p: 3x4 p/y").intVal == 4

suite "tuple path access":
  test "tuple/1":
    check evalStr("t: 1.2.3 t/1").intVal == 1
  test "tuple/3":
    check evalStr("t: 1.2.3 t/3").intVal == 3

# ============================================================
# Literal copy regression
# ============================================================

suite "literal copy in functions":
  test "block literals fresh each call":
    let eval = makeEval()
    discard eval.evalString("f: function [] [r: [] append r 1 r]")
    check eval.evalString("f").blockVals.len == 1
    check eval.evalString("f").blockVals.len == 1

  test "string literals fresh each call":
    let eval = makeEval()
    discard eval.evalString("f: function [] [s: \"\" append s \"x\" s]")
    check eval.evalString("f").strVal == "x"
    check eval.evalString("f").strVal == "x"
