## Tests for lib/io.ktg — the multi-target filesystem binding module.
##
## The module aliases each target's filesystem namespace to a short
## local name so Kintsugi code can reach through to the target's
## native FS API without re-declaring bindings at every call site.
##
## Per-target aliases:
##   love2d     → love-fs   = love.filesystem
##   playdate   → pd-file   = playdate.file  (emitted with <const>)
##   lua        → lua-io    = io
##              → lua-os    = os

import std/unittest
import std/strutils
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/loop_dialect
import ../src/parse/parser
import ../src/emit/lua
import ./emit_test_helper

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval

suite "io module: compiler":
  test "love2d target imports love.filesystem as love-fs":
    let code = emitLua(parseSource("""
      Kintsugi [target: 'love2d]
      import 'io
      contents: love-fs/read "save.dat"
    """))
    check "local love_fs = love.filesystem" in code
    check "love_fs.read(" in code

  test "playdate target imports playdate.file as pd-file with <const>":
    let code = emitLua(parseSource("""
      Kintsugi [target: 'playdate]
      import 'io
      ok: pd-file/exists "save.dat"
    """))
    check "local pd_file <const> = playdate.file" in code
    check "pd_file.exists(" in code

  test "lua target imports io as lua-io":
    let code = emitLua(parseSource("""
      Kintsugi [target: 'lua]
      import 'io
      h: lua-io/open "file.txt" "r"
    """))
    check "local lua_io = io" in code
    check "lua_io.open(" in code

  test "lua target also exposes os as lua-os":
    let code = emitLua(parseSource("""
      Kintsugi [target: 'lua]
      import 'io
      t: lua-os/time
    """))
    check "local lua_os = io" notin code  # sanity: must not confuse os with io
    check "local lua_os = os" in code

  test "default (no target) does not emit any target-specific alias":
    let code = emitLua(parseSource("""
      Kintsugi []
      import 'io
    """))
    check "love.filesystem" notin code
    check "playdate.file" notin code

suite "io module: interpreter":
  test "importing io in the interpreter does not raise":
    let eval = makeEval()
    discard eval.evalString("import 'io")
    # Interpreter has no target, so the alias placeholders install as
    # none — no-op entries that don't interfere with runtime.
