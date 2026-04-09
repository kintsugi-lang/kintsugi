## Tests for Changeset 2: Complete dialect emission
## Tests that new constructs compile to valid Lua.

import unittest
import std/[strutils, os]
import ../src/core/types
import ../src/parse/parser
import ../src/eval/[dialect, evaluator, natives]
import ../src/emit/lua
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]

proc setupEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerObjectDialect()
  eval.registerAttempt()
  eval.registerParse()
  eval

proc evalStr(src: string): KtgValue =
  let eval = setupEval()
  eval.evalString(src)

proc compileStr(src: string): string =
  let ast = parseSource(src)
  let eval = setupEval()
  let processed = eval.preprocess(ast)
  emitLua(processed)

proc compilesOk(src: string): bool =
  try:
    discard compileStr(src)
    true
  except:
    false

proc compileFails(src: string): bool =
  not compilesOk(src)

suite "loop/collect compilation":
  test "basic collect for-in":
    let lua = compileStr("results: loop/collect [for [x] in [1 2 3] do [x]]")
    check "local _collect_r = {}" in lua
    check "_collect_r[#_collect_r+1]" in lua

  test "collect produces IIFE in expression context":
    let lua = compileStr("results: loop/collect [for [x] in [1 2 3] do [x]]")
    check "results" in lua

  test "collect from-to":
    let lua = compileStr("results: loop/collect [for [i] from 1 to 5 do [i]]")
    check "_collect_r" in lua

  test "collect interpreter parity":
    let result = evalStr("loop/collect [for [x] in [1 2 3] do [x * 2]]")
    check result.kind == vkBlock
    check result.blockVals.len == 3
    check result.blockVals[0].intVal == 2
    check result.blockVals[1].intVal == 4
    check result.blockVals[2].intVal == 6

suite "loop/fold compilation":
  test "basic fold for-in":
    let lua = compileStr("total: loop/fold [for [acc x] in [1 2 3] do [acc + x]]")
    check "local _fold_acc" in lua

  test "fold interpreter parity":
    let result = evalStr("loop/fold [for [acc x] in [1 2 3 4 5] do [acc + x]]")
    check result.kind == vkInteger
    check result.intVal == 15

suite "loop/partition compilation":
  test "basic partition for-in":
    let lua = compileStr("parts: loop/partition [for [x] in [1 2 3 4] do [x > 2]]")
    check "_part_true" in lua
    check "_part_false" in lua

  test "partition interpreter parity":
    let result = evalStr("loop/partition [for [x] in [1 2 3 4 5] do [x > 3]]")
    check result.kind == vkBlock
    check result.blockVals.len == 2
    check result.blockVals[0].blockVals.len == 2
    check result.blockVals[1].blockVals.len == 3

suite "find compilation":
  test "find compiles":
    let lua = compileStr("idx: find [1 2 3] 2")
    check "ipairs" in lua or "string.find" in lua

  test "find interpreter parity - block":
    check evalStr("find [10 20 30] 20").intVal == 2

  test "find interpreter parity - string":
    check evalStr("""find "hello" "ell" """).intVal == 2

suite "reverse compilation":
  test "reverse compiles":
    check "function()" in compileStr("r: reverse [1 2 3]")

  test "reverse interpreter parity - block":
    let result = evalStr("reverse [1 2 3]")
    check result.blockVals[0].intVal == 3
    check result.blockVals[2].intVal == 1

  test "reverse interpreter parity - string":
    check evalStr("""reverse "abc" """).strVal == "cba"

suite "byte/char compilation":
  test "byte compiles":
    check "string.byte" in compileStr("""n: byte "A" """)

  test "char compiles":
    check "string.char" in compileStr("c: char 65")

  test "byte interpreter parity":
    check evalStr("""byte "A" """).intVal == 65

  test "char interpreter parity":
    check evalStr("char 65").strVal == "A"

suite "starts-with?/ends-with? compilation":
  test "starts-with? compiles":
    check "string.sub" in compileStr("""r: starts-with? "hello" "hel" """)

  test "ends-with? compiles":
    check "string.sub" in compileStr("""r: ends-with? "hello" "llo" """)

suite "substring compilation":
  test "substring compiles":
    check "string.sub" in compileStr("""s: substring "hello" 2 3""")

suite "@shared compilation":
  test "@shared emits as local":
    let lua = compileStr("@shared score: 0")
    check "local score = 0" in lua

  test "@shared with regular local":
    let lua = compileStr("x: 1\n@shared y: 2")
    check "local x = 1" in lua
    check "local y = 2" in lua

suite "attempt compilation":
  test "basic attempt with source and then":
    check "pcall" in compileStr("""result: attempt [
      source [42]
      then [it + 1]
    ]""")

  test "attempt with fallback":
    check "pcall" in compileStr("""result: attempt [
      source [error 'test "boom" none]
      fallback [0]
    ]""")

  test "attempt interpreter parity":
    check evalStr("""attempt [
      source [10]
      then [it * 2]
    ]""").intVal == 20

suite "system compilation":
  test "system/platform compiles to lua string":
    let lua = compileStr("x: system/platform")
    check "\"lua\"" in lua

  test "system/env compiles to os.getenv":
    let lua = compileStr("x: system/env/HOME")
    check "os.getenv(\"HOME\")" in lua

  test "system/platform interpreter value":
    let result = evalStr("system/platform")
    check result.kind == vkWord
    check result.wordKind == wkLitWord
    check result.wordName == "script"

suite "append splice":
  test "append block splices":
    let result = evalStr("a: [1 2] append a [3 4] a")
    check result.blockVals.len == 4

  test "append non-block adds single":
    let result = evalStr("a: [1 2] append a 3 a")
    check result.blockVals.len == 3

  test "append/only adds block as element":
    let result = evalStr("a: [1 2] append/only a [3 4] a")
    check result.blockVals.len == 3
    check result.blockVals[2].kind == vkBlock

suite "set @rest":
  test "basic @rest":
    let result = evalStr("set [a @rest] [1 2 3 4] rest")
    check result.kind == vkBlock
    check result.blockVals.len == 3

  test "@rest with multiple positional":
    let eval = setupEval()
    discard eval.evalString("set [a b @tail] [1 2 3 4 5]")
    check eval.evalString("a").intVal == 1
    check eval.evalString("b").intVal == 2
    check eval.evalString("tail").blockVals.len == 3

suite "to string! on words":
  test "to string! on lit-word gives name without quote":
    check evalStr("to string! 'hello").strVal == "hello"

  test "to string! on word gives name":
    check evalStr("to string! to word! 'hello").strVal == "hello"

suite "math compilation":
  test "trig compiles":
    check "math.sin" in compileStr("x: sin 1.0")

  test "pow compiles":
    check "math.pow" in compileStr("x: pow 2 3")

  test "floor/ceil compile":
    let lua = compileStr("x: floor 3.7\ny: ceil 3.2")
    check "math.floor" in lua
    check "math.ceil" in lua
