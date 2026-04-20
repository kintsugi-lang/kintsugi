## Tests for the capture native — declarative keyword extraction from blocks.
##
## Result shape: every field on the returned context is a block of
## matches. Each match is itself a block (of values or typed slots).
## Zero matches -> empty block. Stateless: no required/optional/default
## logic in capture itself; callers layer those.

import unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerObjectDialect()
  eval.registerAttempt()
  eval

proc evalStr(src: string): KtgValue =
  let eval = makeEval()
  eval.evalString(src)

suite "capture: always block of matches":
  test "single occurrence, single value -> block with one match block":
    let r = evalStr("parts: capture [retries 3] [@retries] parts/retries")
    check r.kind == vkBlock
    check r.blockVals.len == 1            # one match
    check r.blockVals[0].kind == vkBlock
    check r.blockVals[0].blockVals.len == 1
    check r.blockVals[0].blockVals[0].intVal == 3

  test "single occurrence, block value":
    let r = evalStr("parts: capture [source [42]] [@source] parts/source")
    # parts/source = [[[42]]]  — outer block of matches, each match a block
    check r.kind == vkBlock
    check r.blockVals.len == 1
    check r.blockVals[0].blockVals.len == 1
    check r.blockVals[0].blockVals[0].kind == vkBlock
    check r.blockVals[0].blockVals[0].blockVals[0].intVal == 42

  test "missing keyword -> empty block":
    let r = evalStr("parts: capture [source [42]] [@source @fallback] parts/fallback")
    check r.kind == vkBlock
    check r.blockVals.len == 0

  test "greedy captures multiple values as one match":
    let r = evalStr("parts: capture [tags fast strong agile end] [@tags @end] parts/tags")
    check r.kind == vkBlock
    check r.blockVals.len == 1            # one match
    check r.blockVals[0].blockVals.len == 3  # three values in that match

  test "repeated keyword makes multiple matches":
    let r = evalStr("""
      parts: capture [then [it + 1] then [it * 2]] [@then]
      parts/then
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 2            # two matches
    check r.blockVals[0].blockVals[0].kind == vkBlock   # each match's content
    check r.blockVals[1].blockVals[0].kind == vkBlock

  test "repeated keyword between other keywords":
    let r = evalStr("""
      parts: capture [source [42] then [it + 1] then [it * 2] retries 3] [@source @then @retries]
      parts/then
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 2

  test "pick drills into matches":
    # parts/then has two matches. First match is [[x]] (greedy captured
    # the block value). first gives [x], first gives the word x.
    let r = evalStr("""
      parts: capture [then [x] then [y]] [@then]
      first first first parts/then
    """)
    check r.wordName == "x"

suite "capture: shape specs":
  test "shape with 2 typed slots":
    let r = evalStr("""
      parts: capture [catch 'net [handler]] [@catch [lit-word! block!]]
      parts/catch
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 1
    check r.blockVals[0].blockVals.len == 2
    check r.blockVals[0].blockVals[0].wordName == "net"
    check r.blockVals[0].blockVals[1].kind == vkBlock

  test "shape spec repeats":
    let r = evalStr("""
      parts: capture [catch 'net [h1] catch 'parse [h2]] [@catch [lit-word! block!]]
      parts/catch
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 2
    check r.blockVals[0].blockVals[0].wordName == "net"
    check r.blockVals[1].blockVals[0].wordName == "parse"

  test "shape type mismatch raises":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        capture [catch "net" [handler]] [@catch [lit-word! block!]]
      """)

  test "shape single-slot is still block of matches":
    let r = evalStr("""
      parts: capture [retries 3] [@retries [integer!]]
      parts/retries
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 1
    check r.blockVals[0].blockVals.len == 1
    check r.blockVals[0].blockVals[0].intVal == 3

  test "shape zero matches is empty block":
    let r = evalStr("""
      parts: capture [] [@catch [lit-word! block!]]
      parts/catch
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 0

suite "capture: loop dialect pattern":
  test "captures loop keywords with greedy":
    let eval = makeEval()
    let r = eval.evalString("""
      parts: capture [for [i] in items when [i > 0] do [print i]] [@for @in @when @do]
      parts
    """)
    check r.kind == vkContext
    check r.ctx.get("for").kind == vkBlock
    check r.ctx.get("for").blockVals.len == 1
    check r.ctx.get("do").blockVals.len == 1

  test "optional keyword missing -> empty block":
    let r = evalStr("""
      parts: capture [for [i] in items do [i]] [@for @in @by @when @do]
      parts/by
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 0

suite "capture: attempt dialect pattern":
  test "full attempt pipeline":
    let eval = makeEval()
    let r = eval.evalString("""
      parts: capture [
        source [read %data.txt]
        then [trim it]
        then [uppercase it]
        when [not empty? it]
        fallback ["default"]
        retries 3
      ] [
        @source
        @then
        @when
        @fallback
        @retries [integer!]
      ]
      parts
    """)
    check r.kind == vkContext
    check r.ctx.get("source").blockVals.len == 1      # one source match
    check r.ctx.get("then").blockVals.len == 2        # two then matches
    check r.ctx.get("retries").blockVals[0].blockVals[0].intVal == 3

suite "capture: entity pattern":
  test "game entity definition":
    let eval = makeEval()
    let r = eval.evalString("""
      parts: capture [
        name "Warrior"
        hp 100
        attack 15
        defense 10
        abilities cleave shield
      ] [@name @hp @attack @defense @abilities]
      parts
    """)
    let ctx = r.ctx
    check ctx.get("name").blockVals[0].blockVals[0].strVal == "Warrior"
    check ctx.get("hp").blockVals[0].blockVals[0].intVal == 100
    check ctx.get("abilities").blockVals[0].blockVals.len == 2
