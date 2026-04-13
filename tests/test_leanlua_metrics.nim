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

import std/[unittest, strutils, os]
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
  let source = applyUsingHeader(content)
  let ast = parseSource(source)
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
