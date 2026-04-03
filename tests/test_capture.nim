## Tests for the capture native — declarative keyword extraction from blocks.

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

suite "capture: greedy single":
  test "captures single value after keyword":
    let r = evalStr("parts: capture [retries 3] [@retries] parts/retries")
    check r.intVal == 3

  test "captures block after keyword":
    let r = evalStr("parts: capture [source [42]] [@source] parts/source")
    check r.kind == vkBlock
    check r.blockVals[0].intVal == 42

  test "missing keyword is none":
    let r = evalStr("parts: capture [source [42]] [@source @fallback] parts/fallback")
    check r.kind == vkNone

  test "greedy captures multiple values":
    let r = evalStr("parts: capture [tags fast strong agile end] [@tags @end] parts/tags")
    check r.kind == vkBlock
    check r.blockVals.len == 3

  test "greedy single value unwraps":
    let r = evalStr("parts: capture [name \"Warrior\" hp 100] [@name @hp] parts/name")
    check r.kind == vkString
    check r.strVal == "Warrior"

suite "capture: greedy repeated keywords":
  test "repeated keywords collected with self stripped":
    let r = evalStr("""
      parts: capture [then [it + 1] then [it * 2]] [@then]
      parts/then
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 2
    check r.blockVals[0].kind == vkBlock
    check r.blockVals[1].kind == vkBlock

  test "repeated keyword between other keywords":
    let r = evalStr("""
      parts: capture [source [42] then [it + 1] then [it * 2] retries 3] [@source @then @retries]
      parts/then
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 2

suite "capture: exact /N":
  test "exact captures N values":
    let r = evalStr("""
      parts: capture [catch 'type [handler]] [@catch/2]
      parts/catch
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 2

  test "exact repeating collects":
    let r = evalStr("""
      parts: capture [catch 'type [h1] catch 'math [h2]] [@catch/2]
      parts/catch
    """)
    check r.kind == vkBlock
    check r.blockVals.len == 4  # flat: 'type [h1] 'math [h2]

  test "exact /1 captures single value":
    let r = evalStr("""
      parts: capture [name "Warrior"] [@name/1]
      parts/name
    """)
    check r.strVal == "Warrior"

suite "capture: loop dialect pattern":
  test "captures loop keywords":
    let eval = makeEval()
    let r = eval.evalString("""
      parts: capture [for [i] in items when [i > 0] do [print i]] [@for @in @when @do]
      parts
    """)
    check r.kind == vkContext
    let ctx = r.ctx
    check ctx.get("for").kind == vkBlock   # [i]
    check ctx.get("do").kind == vkBlock    # [print i]

  test "optional keywords are none":
    let r = evalStr("""
      parts: capture [for [i] in items do [i]] [@for @in @by @when @do]
      parts/by
    """)
    check r.kind == vkNone

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
      ] [@source @then @when @fallback @retries]
      parts
    """)
    let ctx = r.ctx
    check ctx.get("source").kind == vkBlock
    check ctx.get("then").kind == vkBlock
    check ctx.get("then").blockVals.len == 2  # two then blocks
    check ctx.get("retries").intVal == 3
    check ctx.get("fallback").kind == vkBlock

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
    check ctx.get("name").strVal == "Warrior"
    check ctx.get("hp").intVal == 100
    check ctx.get("abilities").kind == vkBlock
    check ctx.get("abilities").blockVals.len == 2
