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
    check $eval.evalString("""join "hello" " world" """) == "hello world"
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
    check $eval.evalString("size? [1 2 3]") == "3"
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

suite "pairs":
  test "pair literals and arithmetic":
    let eval = makeEval()
    check $eval.evalString("100x200") == "100x200"
    check $eval.evalString("10x20 + 5x10") == "15x30"

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

suite "freeze":
  test "freeze and frozen?":
    let eval = makeEval()
    discard eval.evalString("c: context [x: 10]")
    check $eval.evalString("frozen? c") == "false"
    discard eval.evalString("f: freeze c")
    check $eval.evalString("frozen? f") == "true"
