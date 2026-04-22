## Color stdlib module tests.

import std/[unittest, math]
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect]

proc makeEval(): Evaluator =
  let e = newEvaluator()
  e.registerNatives()
  e.registerDialect(newLoopDialect())
  e.registerMatch()
  discard e.evalString("import 'color")
  e

proc approx(a, b: float, eps = 0.001): bool = abs(a - b) < eps

proc channels(v: KtgValue): tuple[r, g, b, a: float] =
  check v.kind == vkBlock
  check v.blockVals.len == 4
  for i in 0 ..< 4:
    check v.blockVals[i].kind == vkFloat
  (v.blockVals[0].floatVal, v.blockVals[1].floatVal,
   v.blockVals[2].floatVal, v.blockVals[3].floatVal)

suite "color/rgb":
  test "rgb 255 0 0 is red":
    let e = makeEval()
    let c = channels(e.evalString("color/rgb 255 0 0"))
    check approx(c.r, 1.0)
    check approx(c.g, 0.0)
    check approx(c.b, 0.0)
    check approx(c.a, 1.0)

  test "rgb 0 128 255 mid blue":
    let e = makeEval()
    let c = channels(e.evalString("color/rgb 0 128 255"))
    check approx(c.r, 0.0)
    check approx(c.g, 128.0 / 255.0)
    check approx(c.b, 1.0)
    check approx(c.a, 1.0)

suite "color/rgba":
  test "alpha channel scaled":
    let e = makeEval()
    let c = channels(e.evalString("color/rgba 255 0 0 128"))
    check approx(c.r, 1.0)
    check approx(c.a, 128.0 / 255.0)

suite "color/hex":
  test "#ff0000 -> red":
    let e = makeEval()
    let c = channels(e.evalString("""color/hex "#ff0000" """))
    check approx(c.r, 1.0)
    check approx(c.g, 0.0)
    check approx(c.b, 0.0)
    check approx(c.a, 1.0)

  test "#00ff00 -> green":
    let e = makeEval()
    let c = channels(e.evalString("""color/hex "#00ff00" """))
    check approx(c.g, 1.0)

  test "8-digit hex includes alpha":
    let e = makeEval()
    let c = channels(e.evalString("""color/hex "#ff000080" """))
    check approx(c.r, 1.0)
    check approx(c.a, 128.0 / 255.0)

  test "uppercase hex accepted":
    let e = makeEval()
    let c = channels(e.evalString("""color/hex "#F2BF4D" """))
    check approx(c.r, 242.0 / 255.0)
    check approx(c.g, 191.0 / 255.0)
    check approx(c.b, 77.0 / 255.0)

suite "color/hsl":
  test "hsl 0 100 50 is red":
    let e = makeEval()
    let c = channels(e.evalString("color/hsl 0 100 50"))
    check approx(c.r, 1.0)
    check approx(c.g, 0.0)
    check approx(c.b, 0.0)

  test "hsl 120 100 50 is green":
    let e = makeEval()
    let c = channels(e.evalString("color/hsl 120 100 50"))
    check approx(c.r, 0.0)
    check approx(c.g, 1.0)
    check approx(c.b, 0.0)

  test "hsl 240 100 50 is blue":
    let e = makeEval()
    let c = channels(e.evalString("color/hsl 240 100 50"))
    check approx(c.b, 1.0)

  test "hsl lightness 0 is black":
    let e = makeEval()
    let c = channels(e.evalString("color/hsl 0 100 0"))
    check approx(c.r, 0.0)
    check approx(c.g, 0.0)
    check approx(c.b, 0.0)

  test "hsl lightness 100 is white":
    let e = makeEval()
    let c = channels(e.evalString("color/hsl 0 100 100"))
    check approx(c.r, 1.0)
    check approx(c.g, 1.0)
    check approx(c.b, 1.0)

suite "color math":
  test "lighten moves toward white":
    let e = makeEval()
    let c = channels(e.evalString("color/lighten (color/rgb 100 100 100) 0.5"))
    check c.r > (100.0 / 255.0)
    check c.g > (100.0 / 255.0)

  test "darken moves toward black":
    let e = makeEval()
    let c = channels(e.evalString("color/darken (color/rgb 200 200 200) 0.5"))
    check c.r < (200.0 / 255.0)

  test "mix of red and blue at 0.5 is purple-ish":
    let e = makeEval()
    let c = channels(e.evalString(
      "color/mix (color/rgb 255 0 0) (color/rgb 0 0 255) 0.5"))
    check approx(c.r, 0.5)
    check approx(c.b, 0.5)
    check approx(c.g, 0.0)

  test "mix at 0 returns first color":
    let e = makeEval()
    let c = channels(e.evalString(
      "color/mix (color/rgb 255 0 0) (color/rgb 0 0 255) 0"))
    check approx(c.r, 1.0)
    check approx(c.b, 0.0)

  test "mix at 1 returns second color":
    let e = makeEval()
    let c = channels(e.evalString(
      "color/mix (color/rgb 255 0 0) (color/rgb 0 0 255) 1"))
    check approx(c.r, 0.0)
    check approx(c.b, 1.0)

suite "color/apply":
  test "apply calls 4-arity fn with channels":
    let e = makeEval()
    let rec = e.evalString("""
      record: [0 0 0 0]
      sink: function [a b c d] [record: reduce [a b c d]  0]
      color/apply :sink color/rgb 255 0 0
      record
    """)
    let c = channels(rec)
    check approx(c.r, 1.0)
    check approx(c.g, 0.0)
