## Tests for std namespace, using, and merge

import unittest
import std/[os, osproc, strutils]
import ../src/core/types
import ../src/parse/parser
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

# Note: these tests don't load stdlib (no loadStdlib call).
# They test merge and the stdlib via import.

proc evalStr(src: string): KtgValue =
  let eval = makeEval()
  eval.evalString(src)

suite "merge":
  test "merge overwrites target fields":
    let eval = makeEval()
    let r = eval.evalString("""
      a: context [x: 1 y: 2]
      b: context [y: 99 z: 3]
      merge a b
      a
    """)
    check r.ctx.get("x").intVal == 1
    check r.ctx.get("y").intVal == 99
    check r.ctx.get("z").intVal == 3

  test "merge skips none values":
    let eval = makeEval()
    let r = eval.evalString("""
      a: context [x: 1 y: 2]
      b: context [x: none y: 99]
      merge a b
      a
    """)
    check r.ctx.get("x").intVal == 1
    check r.ctx.get("y").intVal == 99

  test "merge returns first arg":
    let eval = makeEval()
    let r = eval.evalString("""
      a: context [x: 1]
      b: context [y: 2]
      result: merge a b
      result/x
    """)
    check r.intVal == 1

  test "merge with capture":
    let eval = makeEval()
    let r = eval.evalString("""
      defaults: context [name: "Unknown" hp: 100 attack: 10]
      parts: capture [name "Warrior" hp 200] [@name @hp @attack]
      merge defaults parts
      defaults
    """)
    check r.ctx.get("name").strVal == "Warrior"
    check r.ctx.get("hp").intVal == 200
    check r.ctx.get("attack").intVal == 10

  test "merge/deep copies blocks":
    let eval = makeEval()
    discard eval.evalString("""
      a: context [items: [1 2 3]]
      b: context [items: [4 5]]
      merge/deep a b
      append a/items 6
    """)
    # deep copy means b's items shouldn't be affected
    let r = eval.evalString("a/items")
    check r.blockVals.len == 3  # [4 5 6]

  test "merge accepts context as source":
    let eval = makeEval()
    let r = eval.evalString("""
      a: context [x: 1]
      b: context [y: 2]
      merge a b
      a/y
    """)
    check r.intVal == 2

suite "std namespace (via CLI)":
  const kintsugi = "bin/kintsugi"

  test "std/math accessible":
    let (output, _) = execCmdEx(kintsugi & " -e \"print std/math/clamp 15 0 10\"")
    check output.strip == "10"

  test "std/collections accessible":
    let (output, _) = execCmdEx(kintsugi & " -e \"probe std/collections/range 1 5\"")
    check "[1 2 3 4 5]" in output

  test "header using unwraps":
    writeFile("/tmp/_ktg_test_using.ktg", "Kintsugi [name: 'test using: [math]]\nprint clamp 15 0 10\n")
    let (output, _) = execCmdEx(kintsugi & " /tmp/_ktg_test_using.ktg")
    check output.strip == "10"

suite "entity dialect pattern":
  test "capture + merge + enrich":
    let eval = makeEval()
    let r = eval.evalString("""
      entity: function [spec [block!]] [
        defaults: context [name: "Unknown" hp: 100 attack: 10 defense: 5]
        merge defaults (capture spec [@name @hp @attack @defense])
        defaults/max-hp: defaults/hp
        defaults
      ]

      warrior: entity [name "Warrior" hp 200 attack 25]
      warrior
    """)
    check r.ctx.get("name").strVal == "Warrior"
    check r.ctx.get("hp").intVal == 200
    check r.ctx.get("max-hp").intVal == 200
    check r.ctx.get("attack").intVal == 25
    check r.ctx.get("defense").intVal == 5
