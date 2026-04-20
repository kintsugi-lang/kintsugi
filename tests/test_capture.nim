## Tests for the capture native — declarative keyword extraction from blocks.
##
## Shape:
##   result/keyword is always a block of matches.
##   match w/o shape and single captured value   -> value itself
##   match w/o shape with multiple captured      -> block of values
##   match w/o shape with zero captured          -> empty block
##   match with 1-slot shape                     -> value (type-checked)
##   match with N-slot shape                     -> block of N values (tuple)
##   result/order                                -> block of lit-words in
##                                                  source order

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

suite "capture: greedy":
  test "single captured value -> match is the value directly":
    let r = evalStr("parts: capture [source [42]] [@source] parts/source")
    check r.kind == vkBlock
    check r.blockVals.len == 1
    check r.blockVals[0].kind == vkBlock
    check r.blockVals[0].blockVals[0].intVal == 42

  test "single scalar capture":
    let r = evalStr("parts: capture [retries 3] [@retries] parts/retries")
    check r.kind == vkBlock
    check r.blockVals.len == 1
    check r.blockVals[0].intVal == 3

  test "missing keyword -> empty block":
    let r = evalStr("parts: capture [source [42]] [@source @fallback] parts/fallback")
    check r.kind == vkBlock
    check r.blockVals.len == 0

  test "multiple captured values under one keyword -> block match":
    let r = evalStr("parts: capture [tags fast strong agile end] [@tags @end] parts/tags")
    check r.kind == vkBlock
    check r.blockVals.len == 1
    check r.blockVals[0].kind == vkBlock
    check r.blockVals[0].blockVals.len == 3

  test "repeated keyword -> multiple matches":
    let r = evalStr("""
      parts: capture [then [a] then [b]] [@then]
      parts/then
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 2
    check r.blockVals[0].kind == vkBlock    # [a]
    check r.blockVals[0].blockVals[0].wordName == "a"
    check r.blockVals[1].kind == vkBlock    # [b]
    check r.blockVals[1].blockVals[0].wordName == "b"

  test "pick drills without extra unwrap":
    let r = evalStr("""
      parts: capture [then [a] then [b]] [@then]
      first first parts/then
    """)
    check r.wordName == "a"

suite "capture: shape specs":
  test "1-slot shape -> match is the value, type-checked":
    let r = evalStr("""
      parts: capture [retries 3] [@retries [integer!]]
      parts/retries
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 1
    check r.blockVals[0].intVal == 3

  test "2-slot shape -> match is a tuple block":
    let r = evalStr("""
      parts: capture [catch 'net [handler]] [@catch [lit-word! block!]]
      parts/catch
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 1
    check r.blockVals[0].kind == vkBlock
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

  test "shape zero matches -> empty block":
    let r = evalStr("""
      parts: capture [] [@catch [lit-word! block!]]
      parts/catch
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 0

suite "capture: order field":
  test "order lists keywords in source order":
    let r = evalStr("""
      parts: capture [source [x] then [y] when [z] then [w]] [@source @then @when]
      parts/order
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 4
    check r.blockVals[0].wordName == "source"
    check r.blockVals[1].wordName == "then"
    check r.blockVals[2].wordName == "when"
    check r.blockVals[3].wordName == "then"
    # All lit-words
    for v in r.blockVals:
      check v.kind == vkWord and v.wordKind == wkLitWord

  test "empty data -> empty order":
    let r = evalStr("""
      parts: capture [] [@source @then]
      parts/order
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 0

  test "order + per-keyword matches reconstruct sequence":
    # source [x] then [y] when [z] then [w]
    # order  = ['source 'then 'when 'then]
    # source = [[x]]
    # then   = [[y] [w]]
    # when   = [[z]]
    # Walk order, consume from each keyword's match list in turn.
    let r = evalStr("""
      parts: capture [source [x] then [y] when [z] then [w]] [@source @then @when]
      parts
    """)
    check r.kind == vkContext
    check r.ctx.get("order").blockVals.len == 4
    check r.ctx.get("source").blockVals.len == 1
    check r.ctx.get("then").blockVals.len == 2
    check r.ctx.get("when").blockVals.len == 1

suite "capture: loop dialect pattern":
  test "captures loop keywords with greedy":
    let r = evalStr("""
      parts: capture [for [i] in items when [i > 0] do [print i]] [@for @in @when @do]
      parts
    """)
    check r.kind == vkContext
    # for match = [i] (single capture -> value directly = the block [i])
    check r.ctx.get("for").blockVals[0].kind == vkBlock
    check r.ctx.get("do").blockVals[0].kind == vkBlock

  test "optional keyword missing -> empty block":
    let r = evalStr("""
      parts: capture [for [i] in items do [i]] [@for @in @by @when @do]
      parts/by
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 0

suite "capture: attempt dialect pattern":
  test "full attempt pipeline":
    let r = evalStr("""
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
    check r.ctx.get("source").blockVals.len == 1
    check r.ctx.get("then").blockVals.len == 2
    check r.ctx.get("retries").blockVals[0].intVal == 3
    # Cross-keyword ordering preserved via order
    let order = r.ctx.get("order").blockVals
    check order.len == 6
    check order[0].wordName == "source"
    check order[1].wordName == "then"
    check order[2].wordName == "then"
    check order[3].wordName == "when"
    check order[4].wordName == "fallback"
    check order[5].wordName == "retries"

suite "capture: entity pattern":
  test "game entity definition":
    let r = evalStr("""
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
    check ctx.get("name").blockVals[0].strVal == "Warrior"
    check ctx.get("hp").blockVals[0].intVal == 100
    check ctx.get("abilities").blockVals[0].kind == vkBlock
    check ctx.get("abilities").blockVals[0].blockVals.len == 2
