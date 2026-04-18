## Tests for money! compile-time emission and runtime metatable behavior.
##
## Covers:
##   - Emitter: vkMoney emits `_money(cents)` and triggers the `_money` prelude
##   - Prelude: `_money` prelude is absent when money is not used
##   - Runtime: Lua output matches interpreter output via luajit
##     (arithmetic, comparison, print formatting, concat)

import std/[unittest, osproc, os, strutils, sequtils]
import ../src/core/types
import ../src/eval/[evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect,
                        attempt_dialect, parse_dialect]
import ../src/parse/[lexer, parser]
import ../src/emit/lua
import ./emit_test_helper

proc makeEval(): Evaluator =
  result = newEvaluator()
  result.registerNatives()
  result.registerDialect(newLoopDialect())
  result.registerMatch()
  result.registerObjectDialect()
  result.registerAttempt()
  result.registerParse()

proc compileSrc(src: string): string =
  let eval = makeEval()
  let processed = eval.preprocess(parseSource(src), forCompilation = true)
  emitLua(processed)

proc interpLines(src: string): seq[string] =
  let eval = makeEval()
  discard eval.evalString(src)
  eval.output

proc luaLines(src: string): seq[string] =
  let luaCode = compileSrc(src)
  let tmpFile = getTempDir() / "kintsugi_money_test.lua"
  writeFile(tmpFile, luaCode)
  let (output, exitCode) = execCmdEx("luajit " & tmpFile)
  removeFile(tmpFile)
  if exitCode != 0:
    raise newException(CatchableError,
      "luajit exited with " & $exitCode & ":\n" & output &
      "\n--- Lua source ---\n" & luaCode)
  output.strip.splitLines.filterIt(it.len > 0)

proc crossCheck(src: string) =
  let interp = interpLines(src)
  let compiled = luaLines(src)
  if interp != compiled:
    checkpoint("Kintsugi source: " & src)
    checkpoint("Interpreter output: " & $interp)
    checkpoint("Compiler output:    " & $compiled)
    fail()

# ============================================================
# Lexer unit tests — negative money literal is single token
# ============================================================

proc tokens(src: string): seq[KtgValue] =
  var lex = newLexer(src)
  result = @[]
  while true:
    let t = lex.nextToken
    if t.isNil: break
    result.add(t)

suite "lexer: negative money literals":
  test "-$5.00 is a single money token with negative cents":
    let ts = tokens("-$5.00")
    check ts.len == 1
    check ts[0].kind == vkMoney
    check ts[0].cents == -500

  test "-$0.05 preserves sub-dollar cents":
    let ts = tokens("-$0.05")
    check ts.len == 1
    check ts[0].kind == vkMoney
    check ts[0].cents == -5

  test "- $5.00 (with space) is two tokens: op and money":
    # Whitespace-delimited: the space breaks the literal. `-` becomes the
    # subtraction operator and `$5.00` becomes a positive money literal.
    let ts = tokens("- $5.00")
    check ts.len == 2
    check ts[0].kind == vkOp
    check ts[0].opSymbol == "-"
    check ts[1].kind == vkMoney
    check ts[1].cents == 500

  test "$0 - $5 (subtraction between literals) is three tokens":
    let ts = tokens("$0.00 - $5.00")
    check ts.len == 3
    check ts[0].kind == vkMoney
    check ts[0].cents == 0
    check ts[1].kind == vkOp
    check ts[1].opSymbol == "-"
    check ts[2].kind == vkMoney
    check ts[2].cents == 500

  test "-5 still works as negative integer":
    let ts = tokens("-5")
    check ts.len == 1
    check ts[0].kind == vkInteger
    check ts[0].intVal == -5

  test "-3.14 still works as negative float":
    let ts = tokens("-3.14")
    check ts.len == 1
    check ts[0].kind == vkFloat

# ============================================================
# Interpreter unit tests for native fixes
# ============================================================

suite "interpreter: negate and abs on money":
  test "negate on positive money":
    let eval = makeEval()
    check $eval.evalString("negate $5.00") == "-$5.00"

  test "negate on negative money":
    let eval = makeEval()
    check $eval.evalString("negate -$5.00") == "$5.00"

  test "negate on zero money":
    let eval = makeEval()
    check $eval.evalString("negate $0.00") == "$0.00"

  test "abs on money raises type error":
    # Money has no natural unsigned magnitude — use `negate` if flipping
    # sign is what you want. `abs` is reserved for unsigned magnitude of
    # dimensionless numerics.
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("abs $5.00")

  test "abs on money error message points at negate":
    let eval = makeEval()
    try:
      discard eval.evalString("abs $5.00")
      fail()
    except KtgError as e:
      check "money" in e.msg
      check "negate" in e.msg

  test "negate money via assignment":
    let eval = makeEval()
    discard eval.evalString("m: $12.34")
    check $eval.evalString("negate m") == "-$12.34"

# ============================================================
# Emitter unit tests
# ============================================================

suite "emitter: money metatable emission":
  test "money literal emits _money() call":
    let code = compileSrc("m: $12.34")
    check "_money(1234)" in code
    check "local m = _money(1234)" in code

  test "money literal triggers _money prelude":
    let code = compileSrc("m: $12.34\nprint m")
    check "function _money(cents)" in code
    check "_money_mt" in code
    check "__tostring" in code
    check "__add" in code
    check "__concat" in code

  test "no money usage omits _money prelude":
    let code = compileSrc("x: 1 + 2\nprint x")
    check "_money_mt" notin code
    check "function _money" notin code

  test "negative money literal emits negative cents":
    # `-$5.00` is lexed as a single negative money literal (whitespace-
    # delimited unary minus), so the emitted call carries negative cents
    # directly rather than invoking __unm at runtime.
    let code = compileSrc("m: -$5.00")
    check "_money(-500)" in code

  test "subtraction with space between minus and money":
    # `$0.00 - $5.00` — the `-` is separated by whitespace, so it remains
    # the subtraction operator and both operands emit as positive.
    let code = compileSrc("m: $0.00 - $5.00")
    check "_money(0)" in code
    check "_money(500)" in code

  test "zero money literal emits zero cents":
    let code = compileSrc("m: $0.00")
    check "_money(0)" in code

  test "sub-dollar money literal preserves cents":
    let code = compileSrc("m: $0.05")
    check "_money(5)" in code

suite "emitter: abs rejects money at compile time":
  test "abs on money literal is a compile error":
    expect EmitError:
      discard compileSrc("print abs $5.00")

  test "abs on typed money param is a compile error":
    expect EmitError:
      discard compileSrc("""
        f: function [m [money!]] [abs m]
        print f $5.00
      """)

  test "abs error message names negate":
    try:
      discard compileSrc("print abs $5.00")
      fail()
    except EmitError as e:
      check "money" in e.msg
      check "negate" in e.msg

  test "abs on integer still compiles":
    let code = compileSrc("print abs -5")
    check "math.abs" in code

  test "abs on float still compiles":
    let code = compileSrc("print abs -3.14")
    check "math.abs" in code

# ============================================================
# Runtime formatting — interpreter vs compiled Lua parity
# ============================================================

suite "money runtime: print formatting":
  test "whole-dollar amounts":
    crossCheck("print $10.00")
    crossCheck("print $1.00")

  test "with cents":
    crossCheck("print $19.99")
    crossCheck("print $12.34")

  test "cents under ten pad with zero":
    crossCheck("print $1.05")
    crossCheck("print $0.05")
    crossCheck("print $0.09")

  test "zero money":
    crossCheck("print $0.00")

  test "large amount":
    crossCheck("print $9999.99")

  test "negative money literal via unary minus":
    # Whitespace-delimited: `-$5.00` is a single negative-money literal;
    # `- $5.00` (with space) is subtraction. Both resolve to the same
    # value when the left side is zero.
    crossCheck("print -$5.00")
    crossCheck("print -$0.50")
    crossCheck("print -$0.09")

  test "money produced by subtraction":
    crossCheck("print $0.00 - $0.50")
    crossCheck("print $1.00 - $5.25")

# ============================================================
# Runtime arithmetic
# ============================================================

suite "money runtime: arithmetic":
  test "money + money":
    crossCheck("print $10.00 + $5.50")
    crossCheck("print $0.01 + $0.02")

  test "money - money":
    crossCheck("print $10.00 - $3.25")
    crossCheck("print $5.00 - $5.00")

  test "money * integer":
    crossCheck("print $1.00 * 3")
    crossCheck("print $2.50 * 4")

  test "integer * money":
    crossCheck("print 3 * $1.00")
    crossCheck("print 4 * $2.50")

  test "money / integer":
    crossCheck("print $10.00 / 2")
    crossCheck("print $9.00 / 3")

  test "negate on money variable":
    crossCheck("""
      m: $5.00
      print negate m
    """)
    crossCheck("""
      m: $0.25
      print negate m
    """)

  test "negate on money zero":
    crossCheck("""
      m: $0.00
      print negate m
    """)

  test "chained money arithmetic":
    crossCheck("print $1.00 + $2.00 + $3.00")
    crossCheck("print $10.00 - $3.00 - $2.00")

# ============================================================
# Runtime comparison
# ============================================================

suite "money runtime: comparison":
  test "money = money":
    crossCheck("print $1.00 = $1.00")
    crossCheck("print $1.00 = $2.00")

  test "money <> money":
    crossCheck("print $1.00 <> $2.00")
    crossCheck("print $1.00 <> $1.00")

  test "money < money":
    crossCheck("print $1.00 < $2.00")
    crossCheck("print $2.00 < $1.00")

  test "money <= money":
    crossCheck("print $1.00 <= $1.00")
    crossCheck("print $1.00 <= $2.00")
    crossCheck("print $3.00 <= $2.00")

  test "money > money":
    crossCheck("print $2.00 > $1.00")
    crossCheck("print $1.00 > $2.00")

  test "money >= money":
    crossCheck("print $1.00 >= $1.00")
    crossCheck("print $2.00 >= $1.00")
    crossCheck("print $1.00 >= $2.00")

# ============================================================
# Runtime concat — rejoin with money
# ============================================================

suite "money runtime: concat in rejoin":
  test "money value embeds as formatted string":
    crossCheck("""print rejoin ["Price: " $9.99] """)

  test "multiple money values in rejoin":
    crossCheck("""print rejoin ["A: " $1.00 " B: " $2.50] """)

  test "money in print of block":
    crossCheck("""
      m: $12.34
      print rejoin ["total: " m]
    """)

# ============================================================
# Money bound to a variable
# ============================================================

suite "money runtime: variables":
  test "assign and print":
    crossCheck("""
      m: $19.99
      print m
    """)

  test "assign and add":
    crossCheck("""
      a: $10.00
      b: $5.50
      print a + b
    """)

  test "money in function body":
    crossCheck("""
      total: function [a b] [a + b]
      print total $3.00 $4.50
    """)

  test "money/cents field access reads integer cents":
    # Exercises the cents path-accessor through the compiled backend.
    crossCheck("""
      m: $19.99
      print m/cents
    """)
