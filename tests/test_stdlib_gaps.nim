## Tests for previously untested stdlib functions

import unittest
import std/tables
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
# Math: smoothstep / smootherstep
# ============================================================

suite "math: smoothstep":
  test "smoothstep 0 = 0":
    check evalStr("m: import %lib/math.ktg m/smoothstep 0.0").floatVal == 0.0

  test "smoothstep 1 = 1":
    check evalStr("m: import %lib/math.ktg m/smoothstep 1.0").floatVal == 1.0

  test "smoothstep 0.5 = 0.5":
    check evalStr("m: import %lib/math.ktg m/smoothstep 0.5").floatVal == 0.5

  test "smootherstep 0 = 0":
    check evalStr("m: import %lib/math.ktg m/smootherstep 0.0").floatVal == 0.0

  test "smootherstep 1 = 1":
    check evalStr("m: import %lib/math.ktg m/smootherstep 1.0").floatVal == 1.0

  test "smootherstep 0.5 = 0.5":
    let r = evalStr("m: import %lib/math.ktg m/smootherstep 0.5")
    check r.floatVal > 0.49
    check r.floatVal < 0.51

# ============================================================
# Math: fraction
# ============================================================

suite "math: fraction":
  test "fraction of 3.75 = 0.75":
    let r = evalStr("m: import %lib/math.ktg m/fraction 3.75")
    check r.floatVal == 0.75

  test "fraction of integer = 0":
    let r = evalStr("m: import %lib/math.ktg m/fraction 5.0")
    check r.floatVal == 0.0

# ============================================================
# Math: magnitude / normalize
# ============================================================

suite "math: magnitude":
  test "magnitude of 3x4 = 5":
    check evalStr("m: import %lib/math.ktg m/magnitude 3x4").floatVal == 5.0

  test "magnitude of 0x0 = 0":
    check evalStr("m: import %lib/math.ktg m/magnitude 0x0").floatVal == 0.0

suite "math: normalize":
  test "normalize 0x0 = 0x0":
    let r = evalStr("m: import %lib/math.ktg m/normalize 0x0")
    check r.kind == vkPair
    check r.px == 0
    check r.py == 0

  test "normalize 10x0":
    let r = evalStr("m: import %lib/math.ktg m/normalize 10x0")
    check r.kind == vkPair
    check r.px == 1
    check r.py == 0

# ============================================================
# Math: angle-between
# ============================================================

suite "math: angle-between":
  test "angle from origin to east = 0":
    let r = evalStr("m: import %lib/math.ktg m/angle-between 0x0 1x0")
    check r.floatVal == 0.0

  test "angle from origin to north":
    let r = evalStr("m: import %lib/math.ktg m/angle-between 0x0 0x1")
    # atan2(1, 0) = pi/2
    check r.floatVal > 1.57
    check r.floatVal < 1.58

# ============================================================
# Math: deadzone
# ============================================================

suite "math: deadzone":
  test "below threshold returns 0":
    check evalStr("m: import %lib/math.ktg m/deadzone 0.05 0.1").intVal == 0

  test "above threshold returns value":
    check evalStr("m: import %lib/math.ktg m/deadzone 0.5 0.1").floatVal == 0.5

  test "negative below threshold returns 0":
    check evalStr("m: import %lib/math.ktg m/deadzone -0.05 0.1").intVal == 0

# ============================================================
# Math: remap
# ============================================================

suite "math: remap":
  test "remap midpoint":
    # 5 in 0..10 maps to 50 in 0..100
    check evalStr("m: import %lib/math.ktg m/remap 5 0 10 0 100").floatVal == 50.0

  test "remap boundaries":
    check evalStr("m: import %lib/math.ktg m/remap 0 0 10 0 100").intVal == 0
    check evalStr("m: import %lib/math.ktg m/remap 10 0 10 0 100").intVal == 100

# ============================================================
# Math: wrap
# ============================================================

suite "math: wrap":
  test "value in range unchanged":
    check evalStr("m: import %lib/math.ktg m/wrap 5 0 10").intVal == 5

  test "value above range wraps":
    check evalStr("m: import %lib/math.ktg m/wrap 12 0 10").intVal == 2

  test "value below range wraps":
    check evalStr("m: import %lib/math.ktg m/wrap -1 0 10").intVal == 9

# ============================================================
# Collections: tally
# ============================================================

suite "collections: tally":
  test "counts occurrences":
    let r = evalStr("c: import %lib/collections.ktg c/tally [1 2 1 3 2 1]")
    check r.kind == vkMap
    check r.mapEntries["1"].intVal == 3
    check r.mapEntries["2"].intVal == 2
    check r.mapEntries["3"].intVal == 1

# ============================================================
# Collections: flatten-deep (standalone)
# ============================================================

suite "collections: flatten-deep":
  test "deeply nested":
    let r = evalStr("c: import %lib/collections.ktg c/flatten-deep [[[1] [2 [3]]] [[4]]]")
    check r.blockVals.len == 4
    check r.blockVals[0].intVal == 1
    check r.blockVals[3].intVal == 4
