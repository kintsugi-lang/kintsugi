## Tagged union type syntax: `@type [['circle float!] | ['rect float! float!]]`.
## Nominal-by-tag unions with positional field types; match destructures
## by the leading lit-word.

import std/[unittest, tables]
import ../src/core/[types, errors]
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect]
import ../src/analyze/exhaustiveness
import ../src/parse/parser

proc makeEval(): Evaluator =
  let e = newEvaluator()
  e.registerNatives()
  e.registerDialect(newLoopDialect())
  e.registerMatch()
  e

suite "tagged union: registration":
  test "registers as tkTagged in typeDefs":
    let e = makeEval()
    discard e.evalString(
      "shape!: @type [['circle float!] | ['rect float! float!]]")
    check "shape!" in e.typeDefs
    check e.typeDefs["shape!"].kind == tkTagged

suite "tagged union: is?":
  test "accepts matching tag + arity":
    let e = makeEval()
    discard e.evalString(
      "shape!: @type [['circle float!] | ['rect float! float!]]")
    check $e.evalString("is? shape! ['circle 2.5]") == "true"
    check $e.evalString("is? shape! ['rect 3.0 4.0]") == "true"

  test "rejects unknown tag":
    let e = makeEval()
    discard e.evalString(
      "shape!: @type [['circle float!] | ['rect float! float!]]")
    check $e.evalString("is? shape! ['triangle 1.0 2.0 3.0]") == "false"

  test "rejects wrong arity":
    let e = makeEval()
    discard e.evalString(
      "shape!: @type [['circle float!] | ['rect float! float!]]")
    check $e.evalString("is? shape! ['circle 1.0 2.0]") == "false"
    check $e.evalString("is? shape! ['rect 5.0]") == "false"

  test "rejects non-block":
    let e = makeEval()
    discard e.evalString(
      "shape!: @type [['circle float!] | ['rect float! float!]]")
    check $e.evalString("is? shape! 42") == "false"
    check $e.evalString("is? shape! \"rect\"") == "false"

  test "rejects wrong field type":
    let e = makeEval()
    discard e.evalString(
      "shape!: @type [['circle float!] | ['rect float! float!]]")
    check $e.evalString("""is? shape! ['circle "big"]""") == "false"

suite "tagged union: match destructure":
  test "match covers each variant":
    let e = makeEval()
    discard e.evalString(
      "shape!: @type [['circle float!] | ['rect float! float!]]")
    discard e.evalString("""
      area: function [s [shape!]] [
        match s [
          ['circle r]  [r * r * 3.14]
          ['rect w h]  [w * h]
        ]
      ]
    """)
    check $e.evalString("area ['circle 1.0]") == "3.14"
    check $e.evalString("area ['rect 3.0 4.0]") == "12.0"

suite "tagged union: exhaustiveness":
  test "missing variant raises":
    let e = makeEval()
    discard e.evalString(
      "shape!: @type [['circle float!] | ['rect float! float!]]")
    let src = """
      area: function [s [shape!]] [
        match s [
          ['circle r] [0]
        ]
      ]
    """
    expect KtgError:
      checkExhaustiveness(parseSource(src), e)

  test "all variants covered passes":
    let e = makeEval()
    discard e.evalString(
      "shape!: @type [['circle float!] | ['rect float! float!]]")
    let src = """
      area: function [s [shape!]] [
        match s [
          ['circle r] [0]
          ['rect w h] [0]
        ]
      ]
    """
    checkExhaustiveness(parseSource(src), e)

  test "default covers remaining tagged variants":
    let e = makeEval()
    discard e.evalString(
      "shape!: @type [['circle float!] | ['rect float! float!]]")
    let src = """
      area: function [s [shape!]] [
        match s [
          ['circle r] [0]
          default     [0]
        ]
      ]
    """
    checkExhaustiveness(parseSource(src), e)
