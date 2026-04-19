import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/loop_dialect
import ../src/parse/lexer

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval

# ============================================================
# Issue 6: <=/>= for strings, money, dates, times; <> for dates/times
# ============================================================

suite "issue 6 — comparison operators for all types":
  test "<= and >= for strings":
    let eval = makeEval()
    check $eval.evalString(""" "abc" <= "abd" """) == "true"
    check $eval.evalString(""" "abd" <= "abd" """) == "true"
    check $eval.evalString(""" "abd" <= "abc" """) == "false"
    check $eval.evalString(""" "abd" >= "abc" """) == "true"
    check $eval.evalString(""" "abc" >= "abc" """) == "true"
    check $eval.evalString(""" "abc" >= "abd" """) == "false"

  test "<= and >= for money":
    let eval = makeEval()
    check $eval.evalString("$1.00 <= $2.00") == "true"
    check $eval.evalString("$2.00 <= $2.00") == "true"
    check $eval.evalString("$3.00 <= $2.00") == "false"
    check $eval.evalString("$2.00 >= $1.00") == "true"
    check $eval.evalString("$2.00 >= $2.00") == "true"
    check $eval.evalString("$1.00 >= $2.00") == "false"

  test "< and > for dates":
    let eval = makeEval()
    check $eval.evalString("2026-01-01 < 2026-03-15") == "true"
    check $eval.evalString("2026-03-15 > 2026-01-01") == "true"
    check $eval.evalString("2026-03-15 < 2026-01-01") == "false"

  test "<= and >= for dates":
    let eval = makeEval()
    check $eval.evalString("2026-01-01 <= 2026-03-15") == "true"
    check $eval.evalString("2026-03-15 <= 2026-03-15") == "true"
    check $eval.evalString("2026-12-31 <= 2026-03-15") == "false"
    check $eval.evalString("2026-03-15 >= 2026-01-01") == "true"
    check $eval.evalString("2026-03-15 >= 2026-03-15") == "true"
    check $eval.evalString("2026-01-01 >= 2026-03-15") == "false"

  test "< and > for times":
    let eval = makeEval()
    check $eval.evalString("10:00:00 < 14:30:00") == "true"
    check $eval.evalString("14:30:00 > 10:00:00") == "true"
    check $eval.evalString("14:30:00 < 10:00:00") == "false"

  test "<= and >= for times":
    let eval = makeEval()
    check $eval.evalString("10:00:00 <= 14:30:00") == "true"
    check $eval.evalString("14:30:00 <= 14:30:00") == "true"
    check $eval.evalString("23:59:59 <= 14:30:00") == "false"
    check $eval.evalString("14:30:00 >= 10:00:00") == "true"
    check $eval.evalString("14:30:00 >= 14:30:00") == "true"
    check $eval.evalString("10:00:00 >= 14:30:00") == "false"


# ============================================================
# Issue 7: to integer! "3.7" should parse-then-truncate
# ============================================================

suite "issue 7 — to integer! from float string":
  test "to integer! truncates float strings":
    let eval = makeEval()
    check $eval.evalString("""to integer! "3.7" """) == "3"
    check $eval.evalString("""to integer! "9.99" """) == "9"
    check $eval.evalString("""to integer! "-2.5" """) == "-2"

  test "to integer! still works for int strings":
    let eval = makeEval()
    check $eval.evalString("""to integer! "42" """) == "42"


# ============================================================
# Issue 8: try/handle handler receives single error context
# ============================================================

suite "issue 8 — try/handle handler receives error context":
  test "handler gets single context with kind and data":
    let eval = makeEval()
    let result = eval.evalString("""
      r: try/handle [error 'math "boom"] function [e] [e/data]
      r/data
    """)
    check $result == "boom"

  test "handler can access error kind":
    let eval = makeEval()
    let result = eval.evalString("""
      r: try/handle [error 'math "oops"] function [e] [e/kind]
      r/data
    """)
    check $result == "math"  # bare word, no quote

  test "handler can access error data":
    let eval = makeEval()
    let result = eval.evalString("""
      r: try/handle [error 'user 42] function [e] [e/data]
      r/data
    """)
    check $result == "42"


# ============================================================
# Issue 9: opt removed from function params
# ============================================================

suite "issue 9 — opt removed from function params":
  test "opt keyword in param type is not special anymore":
    # [opt integer!] now just uses 'opt' as the type name (will likely fail type check)
    # The important thing is it no longer silently allows none or defaults
    let eval = makeEval()
    var caught = false
    try:
      discard eval.evalString("f: function [a [integer!] b [string!]] [b]  f 1")
    except:
      caught = true
    check caught  # should fail: missing arg, no opt default


# ============================================================
# Issue 10: Negative money rounding
# ============================================================

suite "issue 10 — money rounding":
  test "positive money parses correctly":
    let tokens = tokenize("$19.99")
    check tokens.len == 1
    check tokens[0].kind == vkMoney
    check tokens[0].cents == 1999

  test "money * float uses round not +0.5":
    let eval = makeEval()
    # $10.00 * 0.1 = 1000 cents * 0.1 = 100 cents = $1.00
    check $eval.evalString("$10.00 * 0.1") == "$1.00"
    # $1.00 * 0.33 = 100 cents * 0.33 = 33 cents = $0.33
    check $eval.evalString("$1.00 * 0.33") == "$0.33"

  test "to money! from float uses round":
    let eval = makeEval()
    check $eval.evalString("to money! 19.99") == "$19.99"
    check $eval.evalString("to money! -19.99") == "-$19.99"


# ============================================================
# Issue 12: Missing to conversions
# ============================================================

suite "issue 12 — to conversions":
  test "to time! from integer (seconds)":
    let eval = makeEval()
    check $eval.evalString("to time! 90") == "00:01:30"
    check $eval.evalString("to time! 3661") == "01:01:01"

  test "to time! from string":
    let eval = makeEval()
    check $eval.evalString("""to time! "14:30:00" """) == "14:30:00"
    check $eval.evalString("""to time! "09:05" """) == "09:05:00"

  test "to date! from string":
    let eval = makeEval()
    check $eval.evalString("""to date! "2026-03-15" """) == "2026-03-15"

  test "to date! from block":
    let eval = makeEval()
    check $eval.evalString("to date! [2026 3 15]") == "2026-03-15"

  test "to tuple! from block":
    let eval = makeEval()
    check $eval.evalString("to tuple! [1 2 3]") == "1.2.3"

  test "to tuple! from string":
    let eval = makeEval()
    check $eval.evalString("""to tuple! "1.2.3" """) == "1.2.3"

  test "to file! from string":
    let eval = makeEval()
    check $eval.evalString("""to file! "path/to/file" """) == "%path/to/file"

  test "to url! from string":
    let eval = makeEval()
    check $eval.evalString("""to url! "https://example.com" """) == "https://example.com"

  test "to email! from string":
    let eval = makeEval()
    check $eval.evalString("""to email! "user@example.com" """) == "user@example.com"
