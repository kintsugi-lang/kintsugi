import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/loop_dialect

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval

suite "arithmetic":
  test "basic ops":
    let eval = makeEval()
    check $eval.evalString("1 + 2") == "3"
    check $eval.evalString("10 - 3") == "7"
    check $eval.evalString("4 * 5") == "20"
    check $eval.evalString("10 / 2") == "5"
    check $eval.evalString("10 / 3") == "3.3333333333333335"
    check $eval.evalString("10 % 3") == "1"

  test "left to right":
    let eval = makeEval()
    check $eval.evalString("2 + 3 * 4") == "20"
    check $eval.evalString("2 + (3 * 4)") == "14"

suite "variables":
  test "assignment and lookup":
    let eval = makeEval()
    discard eval.evalString("x: 42")
    check $eval.evalString("x") == "42"
    discard eval.evalString("y: x + 8")
    check $eval.evalString("y") == "50"

suite "strings":
  test "string operations":
    let eval = makeEval()
    check $eval.evalString("""join ["hello" " world"] """) == "hello world"
    check $eval.evalString("""uppercase "hello" """) == "HELLO"
    check $eval.evalString("""lowercase "HELLO" """) == "hello"
    check $eval.evalString("""trim "  hello  " """) == "hello"

suite "logic":
  test "comparisons and not":
    let eval = makeEval()
    check $eval.evalString("1 = 1") == "true"
    check $eval.evalString("1 = 2") == "false"
    check $eval.evalString("1 <> 2") == "true"
    check $eval.evalString("3 > 2") == "true"
    check $eval.evalString("3 < 2") == "false"
    check $eval.evalString("not true") == "false"
    check $eval.evalString("not false") == "true"

suite "blocks":
  test "block operations":
    let eval = makeEval()
    check $eval.evalString("length [1 2 3]") == "3"
    check $eval.evalString("first [10 20 30]") == "10"
    check $eval.evalString("last [10 20 30]") == "30"
    check $eval.evalString("pick [10 20 30] 2") == "20"
    check $eval.evalString("empty? []") == "true"
    check $eval.evalString("empty? [1]") == "false"

suite "functions":
  test "basic function":
    let eval = makeEval()
    discard eval.evalString("add: function [a b] [a + b]")
    check $eval.evalString("add 3 4") == "7"

  test "closures":
    let eval = makeEval()
    discard eval.evalString("make-adder: function [n] [function [x] [x + n]]")
    discard eval.evalString("add5: make-adder 5")
    check $eval.evalString("add5 10") == "15"

  test "early return":
    let eval = makeEval()
    discard eval.evalString("clamp: function [val lo hi] [if val < lo [return lo] if val > hi [return hi] val]")
    check $eval.evalString("clamp 5 1 10") == "5"
    check $eval.evalString("clamp -1 1 10") == "1"
    check $eval.evalString("clamp 15 1 10") == "10"

suite "control flow":
  test "if and either":
    let eval = makeEval()
    check $eval.evalString("if true [42]") == "42"
    check $eval.evalString("if false [42]") == "none"
    check $eval.evalString("either true [1] [2]") == "1"
    check $eval.evalString("either false [1] [2]") == "2"

suite "contexts":
  test "context path access":
    let eval = makeEval()
    discard eval.evalString("point: context [x: 10 y: 20]")
    check $eval.evalString("point/x") == "10"
    check $eval.evalString("point/y") == "20"

suite "truthiness":
  test "truthy and falsy in eval":
    let eval = makeEval()
    check $eval.evalString("if 0 [true]") == "true"
    check $eval.evalString("""if "" [true]""") == "true"
    check $eval.evalString("if [] [true]") == "true"
    check $eval.evalString("if none [true]") == "none"
    check $eval.evalString("if false [true]") == "none"

suite "money":
  test "money literals and arithmetic":
    let eval = makeEval()
    check $eval.evalString("$19.99") == "$19.99"
    check $eval.evalString("$10.00 + $5.50") == "$15.50"
    check $eval.evalString("$10.00 - $3.25") == "$6.75"

  test "money/cents reads integer cents":
    let eval = makeEval()
    discard eval.evalString("m: $19.99")
    check $eval.evalString("m/cents") == "1999"
    discard eval.evalString("n: $0.00 - $0.50")
    check $eval.evalString("n/cents") == "-50"

  test "set-path on money/cents rebinds":
    let eval = makeEval()
    discard eval.evalString("m: $10.00")
    discard eval.evalString("m/cents: 1250")
    check $eval.evalString("m") == "$12.50"

suite "pairs":
  test "pair literals and arithmetic":
    let eval = makeEval()
    check $eval.evalString("100x200") == "100x200"
    check $eval.evalString("10x20 + 5x10") == "15x30"

  test "set-path on pair/x and pair/y rebinds":
    let eval = makeEval()
    discard eval.evalString("p: 10x20")
    discard eval.evalString("p/x: 50")
    check $eval.evalString("p") == "50x20"
    discard eval.evalString("p/y: 99")
    check $eval.evalString("p") == "50x99"

  test "decimal pair literals":
    let eval = makeEval()
    check $eval.evalString("1.5x2.5") == "1.5x2.5"
    check $eval.evalString("1.5x2.5 + 0.5x0.5") == "2x3"
    check $eval.evalString("-1.5x2.0") == "-1.5x2"

  test "pair stringifies as integer when whole-valued":
    let eval = makeEval()
    check $eval.evalString("10x20") == "10x20"
    check $eval.evalString("10.0x20.0") == "10x20"

  test "set-path on pair accepts float":
    let eval = makeEval()
    discard eval.evalString("p: 10x20")
    discard eval.evalString("p/x: 1.5")
    check $eval.evalString("p") == "1.5x20"

  test "to pair! accepts floats":
    let eval = makeEval()
    check $eval.evalString("to pair! [1.5 2.5]") == "1.5x2.5"

  test "pair scaled by scalar":
    let eval = makeEval()
    check $eval.evalString("10x20 * 3") == "30x60"
    check $eval.evalString("3 * 10x20") == "30x60"
    check $eval.evalString("10x20 / 2") == "5x10"
    check $eval.evalString("10x20 * 1.5") == "15x30"

  test "pair abs min max":
    let eval = makeEval()
    check $eval.evalString("abs -10x20") == "10x20"
    check $eval.evalString("abs -10x-20") == "10x20"
    check $eval.evalString("min 10x50 20x40") == "10x40"
    check $eval.evalString("max 10x50 20x40") == "20x50"

  test "nested pair set-path through context":
    let eval = makeEval()
    discard eval.evalString("e: context [pos: 10x20]")
    discard eval.evalString("e/pos/x: 50")
    check $eval.evalString("e/pos") == "50x20"
    discard eval.evalString("e/pos/y: 1.5")
    check $eval.evalString("e/pos") == "50x1.5"

  test "set-path on pair rejects unknown field":
    let eval = makeEval()
    discard eval.evalString("p: 10x20")
    expect KtgError:
      discard eval.evalString("p/z: 5")

suite "type introspection":
  test "type queries":
    let eval = makeEval()
    check $eval.evalString("type 42") == "integer!"
    check $eval.evalString("""type "hello" """) == "string!"
    check $eval.evalString("integer? 42") == "true"
    check $eval.evalString("""string? "hello" """) == "true"
    check $eval.evalString("none? none") == "true"

suite "try/error":
  test "try catches division by zero":
    let eval = makeEval()
    discard eval.evalString("result: try [10 / 0]")
    check $eval.evalString("result/ok") == "false"
    check $eval.evalString("result/kind") == "'math"

suite "loop":
  test "from/to":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("loop [for [x] from 1 to 5 do [print x]]")
    check eval.output == @["1", "2", "3", "4", "5"]

  test "for/in":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("""loop [for [item] in ["a" "b" "c"] do [print item]]""")
    check eval.output == @["a", "b", "c"]

  test "with break":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("loop [for [x] from 1 to 10 do [if x = 4 [break] print x]]")
    check eval.output == @["1", "2", "3"]

  test "scoped vars":
    let eval = makeEval()
    discard eval.evalString("x: 99")
    discard eval.evalString("loop [for [x] from 1 to 3 do [x]]")
    check $eval.evalString("x") == "99"

suite "conversions":
  test "to conversion":
    let eval = makeEval()
    check $eval.evalString("""to integer! "42" """) == "42"
    check $eval.evalString("to float! 7") == "7.0"
    check $eval.evalString("""to string! 42""") == "42"

suite "reduce":
  test "reduce":
    let eval = makeEval()
    check $eval.evalString("reduce [1 + 2 3 * 4]") == "[3 12]"

suite "comparison operators":
  test "integer comparisons":
    let eval = makeEval()
    check $eval.evalString("1 < 2") == "true"
    check $eval.evalString("2 > 1") == "true"
    check $eval.evalString("1 <= 1") == "true"
    check $eval.evalString("2 >= 1") == "true"
    check $eval.evalString("2 < 1") == "false"

  test "float comparisons":
    let eval = makeEval()
    check $eval.evalString("1.5 < 2.5") == "true"
    check $eval.evalString("2.5 > 1.5") == "true"

  test "mixed int/float comparisons":
    let eval = makeEval()
    check $eval.evalString("1 < 2.5") == "true"
    check $eval.evalString("2.5 > 1") == "true"

  test "string comparisons":
    let eval = makeEval()
    check $eval.evalString(""""abc" < "def" """) == "true"
    check $eval.evalString(""""def" > "abc" """) == "true"
    check $eval.evalString(""""abc" <= "abc" """) == "true"

  test "money comparisons":
    let eval = makeEval()
    check $eval.evalString("$1.00 < $2.00") == "true"
    check $eval.evalString("$2.00 > $1.00") == "true"
    check $eval.evalString("$1.00 <= $1.00") == "true"

  test "date comparisons":
    let eval = makeEval()
    check $eval.evalString("2026-01-01 < 2026-12-31") == "true"
    check $eval.evalString("2026-12-31 > 2026-01-01") == "true"

  test "time comparisons":
    let eval = makeEval()
    check $eval.evalString("10:00:00 < 14:30:00") == "true"
    check $eval.evalString("14:30:00 > 10:00:00") == "true"

  test "type mismatch raises error":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""1 < "hello" """)

suite "set-path on scalar value types":
  test "tuple components read and rebind":
    let eval = makeEval()
    discard eval.evalString("v: 1.2.3")
    check $eval.evalString("v/1") == "1"
    check $eval.evalString("v/2") == "2"
    discard eval.evalString("v/2: 99")
    check $eval.evalString("v") == "1.99.3"

  test "tuple set-path out of range errors":
    let eval = makeEval()
    discard eval.evalString("v: 1.2.3")
    expect KtgError:
      discard eval.evalString("v/4: 1")

  test "date components read":
    let eval = makeEval()
    discard eval.evalString("d: 2026-03-15")
    check $eval.evalString("d/year") == "2026"
    check $eval.evalString("d/month") == "3"
    check $eval.evalString("d/day") == "15"

  test "date set-path rebinds with validity check":
    let eval = makeEval()
    discard eval.evalString("d: 2026-03-15")
    discard eval.evalString("d/day: 20")
    check $eval.evalString("d") == "2026-03-20"
    ## Setting month to Feb with day 30 must error.
    discard eval.evalString("d: 2026-03-30")
    expect KtgError:
      discard eval.evalString("d/month: 2")

  test "time components read and rebind":
    let eval = makeEval()
    discard eval.evalString("t: 14:30:00")
    check $eval.evalString("t/hour") == "14"
    check $eval.evalString("t/minute") == "30"
    discard eval.evalString("t/minute: 45")
    check $eval.evalString("t") == "14:45:00"

  test "time set-path out of range errors":
    let eval = makeEval()
    discard eval.evalString("t: 14:30:00")
    expect KtgError:
      discard eval.evalString("t/hour: 24")

suite "series access safety":
  test "first/second/last on blocks":
    let eval = makeEval()
    check $eval.evalString("first [10 20 30]") == "10"
    check $eval.evalString("second [10 20 30]") == "20"
    check $eval.evalString("last [10 20 30]") == "30"

  test "first/second/last on strings":
    let eval = makeEval()
    check $eval.evalString("""first "abc" """) == "a"
    check $eval.evalString("""second "abc" """) == "b"
    check $eval.evalString("""last "abc" """) == "c"

  test "pick with valid index":
    let eval = makeEval()
    check $eval.evalString("pick [10 20 30] 2") == "20"
    check $eval.evalString("""pick "abc" 2""") == "b"

  test "first on empty block raises":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("first []")

  test "pick out of range raises":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("pick [1 2 3] 5")

  test "second on short block raises":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("second [1]")

suite "@template":
  test "@template wraps body in @compose":
    let eval = makeEval()
    check $eval.evalString("""
      @template unless: [cond body [block!]] [
        if not (cond) (body)
      ]
      result: 0
      unless false [result: 42]
      result
    """) == "42"

  test "@template/deep uses @compose/deep":
    let eval = makeEval()
    check $eval.evalString("""
      @template/deep make-adder: [n [integer!]] [
        function [x] [x + (n)]
      ]
      add5: make-adder 5
      add5 10
    """) == "15"

  test "@template/only uses @compose/only":
    let eval = makeEval()
    check $eval.evalString("""
      @template/only defn: [name [string!] params [block!] body [block!]] [
        (to set-word! name) function (params) (body)
      ]
      defn "square" [x] [x * x]
      square 7
    """) == "49"

suite "recursion depth limit":
  test "infinite recursion raises stack overflow":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        inf: function [] [inf]
        inf
      """)

suite "arithmetic errors":
  test "division by zero":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("1 / 0")

  test "modulo by zero":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("10 % 0")

  test "type mismatch in addition":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""1 + "hello" """)

  test "type mismatch in subtraction":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""1 - "hello" """)

suite "type errors":
  test "undefined variable":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("print undefined-var")

  test "wrong arity":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""
        f: function [a b] [a + b]
        f 1
      """)

suite "@exit error guarantee":
  test "@exit runs even when body throws":
    let eval = makeEval()
    discard eval.evalString("""
      cleanup-ran: false
      try [
        @exit [cleanup-ran: true]
        error "test" "deliberate error" none
      ]
    """)
    check $eval.evalString("cleanup-ran") == "true"

suite "lexer errors":
  test "invalid date month":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("x: 2026-13-01")

  test "invalid date day":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("x: 2026-01-32")

  test "invalid time hour":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("x: 24:00:00")

  test "invalid time minute":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("x: 12:60:00")

  test "invalid time second":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("x: 12:30:60")

