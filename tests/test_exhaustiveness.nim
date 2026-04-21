## Static exhaustiveness checks for the match dialect.

import std/unittest
import ../src/core/[types, errors]
import ../src/parse/parser
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect]
import ../src/analyze/exhaustiveness

proc makeEval(): Evaluator =
  let e = newEvaluator()
  e.registerNatives()
  e.registerDialect(newLoopDialect())
  e.registerMatch()
  e

proc registerEnum(e: Evaluator, decl: string) =
  discard e.evalString(decl)

suite "static exhaustiveness - enum":

  test "all variants covered passes":
    let e = makeEval()
    registerEnum(e, "color!: @type/enum ['red | 'green | 'blue]")
    let src = """
      describe: function [c [color!]] [
        match c [
          ['red]   ["r"]
          ['green] ["g"]
          ['blue]  ["b"]
        ]
      ]
    """
    checkExhaustiveness(parseSource(src), e)

  test "missing variant raises":
    let e = makeEval()
    registerEnum(e, "color!: @type/enum ['red | 'green | 'blue]")
    let src = """
      describe: function [c [color!]] [
        match c [
          ['red]   ["r"]
          ['green] ["g"]
        ]
      ]
    """
    expect KtgError:
      checkExhaustiveness(parseSource(src), e)

  test "wildcard catches remaining variants":
    let e = makeEval()
    registerEnum(e, "color!: @type/enum ['red | 'green | 'blue]")
    let src = """
      describe: function [c [color!]] [
        match c [
          ['red] ["r"]
          [_]    ["other"]
        ]
      ]
    """
    checkExhaustiveness(parseSource(src), e)

  test "default catches remaining variants":
    let e = makeEval()
    registerEnum(e, "color!: @type/enum ['red | 'green | 'blue]")
    let src = """
      describe: function [c [color!]] [
        match c [
          ['red]  ["r"]
          default ["other"]
        ]
      ]
    """
    checkExhaustiveness(parseSource(src), e)

  test "guarded arm does not cover its variant":
    let e = makeEval()
    registerEnum(e, "color!: @type/enum ['red | 'green | 'blue]")
    let src = """
      describe: function [c [color!]] [
        match c [
          ['red]   when [true] ["r"]
          ['green] ["g"]
          ['blue]  ["b"]
        ]
      ]
    """
    expect KtgError:
      checkExhaustiveness(parseSource(src), e)

  test "unreachable arm after default":
    let e = makeEval()
    registerEnum(e, "color!: @type/enum ['red | 'green | 'blue]")
    let src = """
      describe: function [c [color!]] [
        match c [
          default  ["other"]
          ['red]   ["r"]
        ]
      ]
    """
    expect KtgError:
      checkExhaustiveness(parseSource(src), e)

  test "duplicate variant arm is unreachable":
    let e = makeEval()
    registerEnum(e, "color!: @type/enum ['red | 'green | 'blue]")
    let src = """
      describe: function [c [color!]] [
        match c [
          ['red]   ["r1"]
          ['red]   ["r2"]
          ['green] ["g"]
          ['blue]  ["b"]
        ]
      ]
    """
    expect KtgError:
      checkExhaustiveness(parseSource(src), e)

  test "untyped scrutinee: no check":
    let e = makeEval()
    registerEnum(e, "color!: @type/enum ['red | 'green | 'blue]")
    let src = """
      describe: function [c] [
        match c [
          ['red] ["r"]
        ]
      ]
    """
    checkExhaustiveness(parseSource(src), e)

suite "static exhaustiveness - builtin union":

  test "all union types covered passes":
    let e = makeEval()
    registerEnum(e, "scalar!: @type [integer! | string!]")
    let src = """
      describe: function [v [scalar!]] [
        match v [
          [integer!] ["i"]
          [string!]  ["s"]
        ]
      ]
    """
    checkExhaustiveness(parseSource(src), e)

  test "missing union type raises":
    let e = makeEval()
    registerEnum(e, "scalar!: @type [integer! | string!]")
    let src = """
      describe: function [v [scalar!]] [
        match v [
          [integer!] ["i"]
        ]
      ]
    """
    expect KtgError:
      checkExhaustiveness(parseSource(src), e)

  test "wildcard covers union remainder":
    let e = makeEval()
    registerEnum(e, "scalar!: @type [integer! | string!]")
    let src = """
      describe: function [v [scalar!]] [
        match v [
          [integer!] ["i"]
          [_]        ["other"]
        ]
      ]
    """
    checkExhaustiveness(parseSource(src), e)

  test "duplicate type arm is unreachable":
    let e = makeEval()
    registerEnum(e, "scalar!: @type [integer! | string!]")
    let src = """
      describe: function [v [scalar!]] [
        match v [
          [integer!] ["i1"]
          [integer!] ["i2"]
          [string!]  ["s"]
        ]
      ]
    """
    expect KtgError:
      checkExhaustiveness(parseSource(src), e)
