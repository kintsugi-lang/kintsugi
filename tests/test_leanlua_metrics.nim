## Targeted lean-lua invariants.
##
## Each test asserts a specific output-quality property that we never
## want to regress. Metrics are added as each lean-lua phase lands -
## they pin the wins so later phases can't silently undo them.
##
## How to read a metric failure: the test name tells you which invariant
## broke. The failure message shows the offending count. Fix the emitter
## or update the metric (with justification) - but never both in the
## same commit.

import std/[unittest, strutils, os, osproc]
import ../src/parse/parser
import ../src/emit/lua
import ../src/eval/[evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect,
                        attempt_dialect, parse_dialect]

proc hasHeader(source: string): bool =
  source.strip.startsWith("Kintsugi")

proc setupEvalForTest(): Evaluator =
  result = newEvaluator()
  result.registerNatives()
  result.registerDialect(newLoopDialect())
  result.registerMatch()
  result.registerObjectDialect()
  result.registerAttempt()
  result.registerParse()
  # NOT loadStdlib() - tests compile goldens that are self-contained.

proc compileGolden(name: string): string =
  let ktgPath = currentSourcePath().parentDir / "golden" / (name & ".ktg")
  let content = readFile(ktgPath)
  let isEntrypoint = hasHeader(content)
  let ast = parseSource(content)
  let eval = setupEvalForTest()
  let processed = eval.preprocess(ast, forCompilation = true)
  let sourceDir = parentDir(absolutePath(ktgPath))
  if isEntrypoint: emitLua(processed, sourceDir)
  else: emitLuaModule(processed, sourceDir)

proc countOccurrences(text, needle: string): int =
  ## Non-overlapping occurrences of `needle` in `text`.
  if needle.len == 0: return 0
  var i = 0
  while true:
    let pos = text.find(needle, i)
    if pos == -1: break
    result += 1
    i = pos + needle.len

proc preludeLineCount(text: string): int =
  ## Number of lines in the leading prelude block, counted up to (not
  ## including) the first blank line. Returns 0 when the output starts
  ## with something other than the `-- Kintsugi runtime support` header
  ## - i.e., no prelude at all.
  ##
  ## Task 16 modifies buildPrelude to always terminate with a blank line,
  ## so this heuristic becomes a precise boundary after Task 16 lands.
  ## Before Task 16, the blank line may be missing and this function
  ## may over-count; that's acceptable because Task 16 is what creates
  ## the metric the function is measuring.
  if not text.startsWith("-- Kintsugi runtime support"):
    return 0
  var lines = 0
  for line in text.split('\n'):
    if line.strip.len == 0:
      break
    lines += 1
    if lines > 200:  # safety bound against runaway
      break
  result = lines

# --- metrics ---

suite "lean-lua metrics":

  # NOTE: metrics are added as each Phase lands. Initial commit has
  # only smoke checks. See plan tasks 2.x through 4.x for the real asserts.

  test "golden compiles parse cleanly (smoke)":
    let hello = compileGolden("hello")
    check hello.len > 0
    let pong = compileGolden("pong")
    check pong.len > 0
    let combat = compileGolden("combat")
    check combat.len > 0

  test "loop/partition inner predicate has no IIFE":
    let stress = compileGolden("leanlua_stress")
    check countOccurrences(stress, "if (function()") == 0

  test "set destructure with loop refinement has no IIFE":
    let stress = compileGolden("leanlua_stress")
    check countOccurrences(stress, "local _set_tmp = (function()") == 0

  test "if as expression uses and-or when body is simple":
    let src = "Kintsugi [name: 'if-expr-test]\nx: if (1 > 0) [42]\nprint x\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check countOccurrences(lua, "(function()") == 0

  test "either as expression uses and-or when both branches are literal":
    let src = "Kintsugi [name: 'either-expr-test]\nprint (either 1 > 0 [\"yes\"] [\"no\"])\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check countOccurrences(lua, "(function()") == 0

  test "rejoin with numeric-literal-returning function has no defensive tostring":
    let src = "Kintsugi [name: 'rejoin-literal-test]\n" &
              "double: function [n [integer!]] [n * 2]\n" &
              "print rejoin [\"r: \" (double 3)]\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check countOccurrences(lua, "tostring(") == 0

  test "loop over context emits pairs not ipairs":
    let src = "Kintsugi [name: 'ctx-loop-test]\n" &
              "c: context [a: 1  b: 2  c: 3]\n" &
              "loop [for [v] in c do [print v]]\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check countOccurrences(lua, "pairs(c)") >= 1
    check countOccurrences(lua, "ipairs(c)") == 0

  test "match conditions have no trailing 'and true'":
    for name in ["hello", "pong", "combat", "playdate", "leanlua_stress"]:
      let lua = compileGolden(name)
      check countOccurrences(lua, "and true") == 0

  test "match integer? emits inline type check":
    let src = "Kintsugi [name: 'match-type-test]\n" &
              "describe: function [v] [match v [[integer?] [\"int\"] default [\"?\"]]]\n" &
              "print describe 42\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check countOccurrences(lua, "type(") >= 1
    check countOccurrences(lua, "_is_integer") == 0

  test "subset on typed string var emits string.sub":
    let src = "Kintsugi [name: 'subset-str-test]\n" &
              "f: function [s [string!]] [subset s 1 3]\n" &
              "print f \"hello\"\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check countOccurrences(lua, "string.sub(") >= 1
    check countOccurrences(lua, "_subset(") == 0

  test "program with no helpers emits zero prelude lines":
    let src = "Kintsugi [name: 'bare-test]\nprint \"hi\"\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check preludeLineCount(lua) == 0
    check not lua.startsWith("-- Kintsugi")
    check not lua.contains("math.randomseed")
    check not lua.contains("local unpack")

  test "program with none always emits _NONE sentinel":
    # Kintsugi none is a first-class value distinct from Lua nil. Without
    # this, `[1 none 3]` would compile to `{1, nil, 3}` which Lua treats
    # as a sparse table - length, ipairs, table.concat all break.
    let src = "Kintsugi [name: 'sentinel-test]\nx: none\nprint x\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check countOccurrences(lua, "_NONE") >= 1

  test "program with none in block emits _NONE sentinel":
    let src = "Kintsugi [name: 'sentinel-test]\n" &
              "items: [1 none 3]\nif none? items/2 [print \"empty\"]\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check countOccurrences(lua, "_NONE") >= 1

  test "program without any none reference omits _NONE prelude":
    let src = "Kintsugi [name: 'no-none]\nx: 42\nprint x\n"
    let ast = parseSource(src)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let lua = emitLua(processed, "")
    check countOccurrences(lua, "_NONE") == 0

  test "goldens never hit the _make fallback":
    for name in ["hello", "pong", "combat", "playdate", "leanlua_stress"]:
      let lua = compileGolden(name)
      check countOccurrences(lua, "_make(") == 0

  # --- end-of-plan exit gates ---

  test "exit gate: hello.lua is strictly lean":
    let lua = compileGolden("hello")
    # Hello uses _copy and _append for qsort plus _prettify for printing
    # blocks (squares, qsort result). Cap accounts for prettify (28 lines)
    # plus other helpers; keeps bloat in check.
    check preludeLineCount(lua) <= 60
    check countOccurrences(lua, "(function()") == 0
    # _prettify replaces tostring for user-visible output. Block-valued
    # expressions (squares, qsort(...)) flow through it.
    check countOccurrences(lua, "_prettify(") <= 6

  test "exit gate: pong.lua is lean":
    let lua = compileGolden("pong")
    # pong uses random + _NONE sentinel for none semantics. Cap at small
    # bound to catch regression bloat.
    check preludeLineCount(lua) <= 6
    check countOccurrences(lua, "_make(") == 0
    check countOccurrences(lua, "(function()") == 0

  test "exit gate: combat.lua prelude is bounded":
    let lua = compileGolden("combat")
    # combat prints rejoined messages with object fields, pulling in
    # _prettify for unknown-typed paths. Cap covers prettify + small
    # helpers without leaving slack for runaway bloat.
    check preludeLineCount(lua) <= 50

  # --- Split-prelude exit gates: source files must be tiny once helpers
  # move into prelude.lua. The combined-form gates above measure the
  # legacy emitLua output; these gates measure the new split.
  proc splitGolden(name: string): tuple[prelude, source: string] =
    let ktgPath = currentSourcePath().parentDir / "golden" / (name & ".ktg")
    let content = readFile(ktgPath)
    let ast = parseSource(content)
    let eval = setupEvalForTest()
    let processed = eval.preprocess(ast, forCompilation = true)
    let sourceDir = parentDir(absolutePath(ktgPath))
    emitLuaSplit(processed, sourceDir)

  test "exit gate (split): hello source is just user code + require":
    let (_, source) = splitGolden("hello")
    # Source line count: require line + qsort fn + a few prints. Keeps
    # the source compact - all helpers live in prelude.
    check source.split('\n').len <= 50
    check "require('prelude')" in source
    check "function _prettify" notin source

  test "exit gate (split): combat source has no helper definitions":
    let (_, source) = splitGolden("combat")
    check "function _prettify" notin source
    check "function _make" notin source
    check "function _NONE" notin source
    check "_pair_mt" notin source
    check "require('prelude')" in source

  test "exit gate (split): pong source has no helper definitions":
    let (_, source) = splitGolden("pong")
    check "function _prettify" notin source
    check "function _make" notin source

  test "exit gate (split): prelude bundles all helpers a program uses":
    let (prelude, _) = splitGolden("hello")
    # Hello touches _copy, _append, _prettify, _NONE
    check "function _prettify" in prelude
    check "function _copy" in prelude
    check "function _append" in prelude

  test "exit gate: script-type goldens run in LuaJIT":
    # Executes compiled output with luajit. Any runtime error -
    # missing helper, bad syntax, undefined global - fails the test.
    # Skips pong/playdate which need Love2D/Playdate runtimes.
    let luaBin = findExe("luajit")
    if luaBin.len == 0:
      skip()
    else:
      let goldenDir = currentSourcePath().parentDir / "golden"
      for name in ["hello", "leanlua_stress", "combat"]:
        let path = goldenDir / (name & ".lua")
        let (output, exitCode) = execCmdEx(luaBin & " " & path)
        if exitCode != 0:
          echo "  [", name, "] exit=", exitCode, " output=\n", output
        check exitCode == 0
