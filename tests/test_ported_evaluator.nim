## Ported from TypeScript tests:
##   evaluator.test.ts, functions.test.ts, context.test.ts,
##   errors.test.ts, homoiconic.test.ts, lifecycle.test.ts
##
## Spec changes applied:
##   1. Set-word ALWAYS shadows (no write-through)
##   2. `try` returns context! — path access result/ok, result/kind
##   3. Closures capture by reference
##   4. `and`/`or` do NOT short-circuit (spec gotchas)
##   5. Loop variables are scoped (don't leak)
##   6. Block equality is structural
##   7. Only `false` and `none` are falsy
##   8. `size?` is canonical, `length?` is alias
##   9. Lifecycle hooks — marked FAILS if not implemented
##  10. `do`, `compose`, `bind` — kept, marked FAILS if not implemented

import std/unittest
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerObjectDialect()
  eval.registerAttempt()
  eval.registerParse()
  eval

# =============================================================================
# evaluator.test.ts — Scalars
# =============================================================================

suite "Scalars":
  test "integer":
    let eval = makeEval()
    check $eval.evalString("42") == "42"

  test "float":
    let eval = makeEval()
    check $eval.evalString("3.14") == "3.14"

  test "string":
    let eval = makeEval()
    check $eval.evalString("\"hello\"") == "hello"

  test "logic":
    let eval = makeEval()
    check $eval.evalString("true") == "true"
    check $eval.evalString("false") == "false"

  test "none":
    let eval = makeEval()
    check $eval.evalString("none") == "none"

# =============================================================================
# evaluator.test.ts — Set-word and word lookup
# =============================================================================

suite "Set-word and word lookup":
  test "bind and retrieve":
    let eval = makeEval()
    discard eval.evalString("x: 42")
    check $eval.evalString("x") == "42"

  test "returns value":
    let eval = makeEval()
    check $eval.evalString("x: 42") == "42"

  test "multiple expressions last wins":
    let eval = makeEval()
    check $eval.evalString("1 2 3") == "3"

# =============================================================================
# evaluator.test.ts — Get-word
# =============================================================================

suite "Get-word":
  test "returns value":
    let eval = makeEval()
    discard eval.evalString("x: 42")
    check $eval.evalString(":x") == "42"

  test "on function":
    let eval = makeEval()
    # :print should return the native function without calling it
    let result = eval.evalString(":print")
    check result.kind == vkNative

# =============================================================================
# evaluator.test.ts — Lit-word
# =============================================================================

suite "Lit-word":
  test "returns self":
    let eval = makeEval()
    check $eval.evalString("'hello") == "'hello"

# =============================================================================
# evaluator.test.ts — Arithmetic operators
# =============================================================================

suite "Arithmetic":
  test "addition":
    let eval = makeEval()
    check $eval.evalString("2 + 3") == "5"

  test "subtraction":
    let eval = makeEval()
    check $eval.evalString("10 - 3") == "7"

  test "multiplication":
    let eval = makeEval()
    check $eval.evalString("4 * 5") == "20"

  test "division":
    let eval = makeEval()
    check $eval.evalString("10 / 2") == "5"
    check $eval.evalString("10 / 5") == "2"
    check $eval.evalString("7 / 2") == "3.5"

  test "left to right":
    let eval = makeEval()
    check $eval.evalString("2 + 3 * 4") == "20"  # no precedence

  test "parens":
    let eval = makeEval()
    check $eval.evalString("2 + (3 * 4)") == "14"

  test "float":
    let eval = makeEval()
    check $eval.evalString("1.5 + 2.5") == "4.0"

  test "string concat":
    let eval = makeEval()
    check $eval.evalString("\"hello\" + \" world\"") == "hello world"

  test "modulo":
    let eval = makeEval()
    check $eval.evalString("10 % 3") == "1"

# =============================================================================
# evaluator.test.ts — Comparison operators
# =============================================================================

suite "Comparison":
  test "equal":
    let eval = makeEval()
    check $eval.evalString("5 = 5") == "true"
    check $eval.evalString("5 = 3") == "false"

  test "not equal":
    let eval = makeEval()
    check $eval.evalString("5 <> 3") == "true"

  test "less than":
    let eval = makeEval()
    check $eval.evalString("3 < 5") == "true"

  test "greater than":
    let eval = makeEval()
    check $eval.evalString("5 > 3") == "true"

  test "less equal":
    let eval = makeEval()
    check $eval.evalString("3 <= 3") == "true"

  test "greater equal":
    let eval = makeEval()
    check $eval.evalString("5 >= 5") == "true"

# =============================================================================
# evaluator.test.ts — Blocks are inert
# =============================================================================

suite "Blocks":
  test "inert":
    let eval = makeEval()
    let result = eval.evalString("[1 + 2]")
    check result.kind == vkBlock
    check result.blockVals.len == 3
    check result.blockVals[0].kind == vkInteger
    check result.blockVals[0].intVal == 1

# =============================================================================
# evaluator.test.ts — Parens evaluate
# =============================================================================

suite "Parens":
  test "evaluate":
    let eval = makeEval()
    check $eval.evalString("(1 + 2)") == "3"

# =============================================================================
# evaluator.test.ts — Set-word with infix
# =============================================================================

suite "Set-word with infix":
  test "captures infix":
    let eval = makeEval()
    discard eval.evalString("x: 2 + 3")
    check $eval.evalString("x") == "5"

# =============================================================================
# evaluator.test.ts — Undefined word error
# =============================================================================

suite "Undefined word":
  test "error on undefined word":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("undefined-word")

# =============================================================================
# functions.test.ts — User-defined functions
# =============================================================================

suite "Functions":
  test "simple":
    let eval = makeEval()
    check $eval.evalString("add: function [a b] [a + b] add 3 4") == "7"

  test "no args":
    let eval = makeEval()
    check $eval.evalString("greet: function [] [42] greet") == "42"

  test "get word retrieves":
    let eval = makeEval()
    discard eval.evalString("add: function [a b] [a + b]")
    let fn = eval.evalString(":add")
    check fn.kind == vkFunction

  test "get word indirect call":
    let eval = makeEval()
    check $eval.evalString("add: function [a b] [a + b] op: :add op 3 4") == "7"

  test "closure captures":
    let eval = makeEval()
    check $eval.evalString("make-adder: function [n] [function [x] [x + n]] add5: make-adder 5 add5 10") == "15"

  test "return early":
    let eval = makeEval()
    check $eval.evalString("f: function [x] [if x > 0 [return x] 0] f 5") == "5"

  test "return else branch":
    let eval = makeEval()
    check $eval.evalString("f: function [x] [if x > 0 [return x] 0] f -1") == "0"

  test "recursive":
    let eval = makeEval()
    check $eval.evalString("fact: function [n] [either n = 0 [1] [n * fact (n - 1)]] fact 5") == "120"

  test "sees globals":
    let eval = makeEval()
    discard eval.evalString("x: 10")
    discard eval.evalString("f: function [y] [x + y]")
    check $eval.evalString("f 5") == "15"

# =============================================================================
# context.test.ts — Scoping (tested via evalString, not direct context API)
# =============================================================================

suite "Context scoping":
  test "set and get":
    let eval = makeEval()
    discard eval.evalString("x: 42")
    check $eval.evalString("x") == "42"

  test "parent chain lookup":
    # Functions see parent scope variables
    let eval = makeEval()
    discard eval.evalString("a: 1")
    discard eval.evalString("f: function [] [a]")
    check $eval.evalString("f") == "1"

  test "shadowing":
    ## Spec rule: set-word ALWAYS shadows, no write-through
    let eval = makeEval()
    discard eval.evalString("x: 1")
    discard eval.evalString("f: function [] [x: 2 x]")
    check $eval.evalString("f") == "2"       # inner x is 2
    check $eval.evalString("x") == "1"       # outer x unchanged — shadowed, not mutated

  test "set always shadows":
    ## Spec rule: set-word in child scope never writes through to parent
    let eval = makeEval()
    discard eval.evalString("x: 1")
    discard eval.evalString("f: function [] [x: 99 x]")
    check $eval.evalString("f") == "99"
    check $eval.evalString("x") == "1"       # parent untouched

  test "path access":
    let eval = makeEval()
    discard eval.evalString("point: context [x: 10 y: 20]")
    check $eval.evalString("point/x") == "10"
    check $eval.evalString("point/y") == "20"

# =============================================================================
# errors.test.ts — Error and try
# =============================================================================

suite "Try and error":
  test "success":
    let eval = makeEval()
    discard eval.evalString("result: try [10 + 5]")
    check $eval.evalString("result/ok") == "true"
    check $eval.evalString("result/value") == "15"
    check $eval.evalString("result/kind") == "none"
    check $eval.evalString("result/message") == "none"
    check $eval.evalString("result/data") == "none"

  test "division by zero":
    let eval = makeEval()
    discard eval.evalString("result: try [10 / 0]")
    check $eval.evalString("result/ok") == "false"
    check $eval.evalString("result/value") == "none"

  test "error with kind and message":
    let eval = makeEval()
    discard eval.evalString("result: try [error 'test-error \"oops\" none]")
    check $eval.evalString("result/ok") == "false"
    check $eval.evalString("result/kind") == "'test-error"
    check $eval.evalString("result/message") == "oops"

  test "error with data":
    let eval = makeEval()
    discard eval.evalString("result: try [error 'bad \"msg\" [x: 1]]")
    check $eval.evalString("result/ok") == "false"
    let data = eval.evalString("result/data")
    check data.kind == vkBlock

  test "error kind only":
    let eval = makeEval()
    discard eval.evalString("result: try [error 'fail none none]")
    check $eval.evalString("result/kind") == "'fail"
    check $eval.evalString("result/message") == "none"

  test "error context":
    let eval = makeEval()
    discard eval.evalString("result: try [10 / 0]")
    check $eval.evalString("result/ok") == "false"
    check $eval.evalString("result/kind") == "'math"

  test "handle receives error and recovers":
    let eval = makeEval()
    discard eval.evalString("handler: function [e] [42]")
    discard eval.evalString("""result: try/handle [error 'bad "oops" none] :handler""")
    check $eval.evalString("result/ok") == "true"  # handler recovered
    check $eval.evalString("result/value") == "42"

  test "handle not called on success":
    let eval = makeEval()
    discard eval.evalString("handler: function [e] [99]")
    discard eval.evalString("result: try/handle [10 + 5] :handler")
    check $eval.evalString("result/ok") == "true"
    check $eval.evalString("result/value") == "15"

  test "handle inline function":
    let eval = makeEval()
    discard eval.evalString("""result: try/handle [error 'fail "boom" none] function [e] [e/message]""")
    check $eval.evalString("result/ok") == "true"
    check $eval.evalString("""result/value""") == "boom"

# =============================================================================
# homoiconic.test.ts — to word types
# =============================================================================

suite "To word types":
  test "to word from string":
    let eval = makeEval()
    let result = eval.evalString("to word! \"hello\"")
    check result.kind == vkWord
    check result.wordName == "hello"

  test "to set-word from string":
    let eval = makeEval()
    let result = eval.evalString("to set-word! \"x\"")
    check result.kind == vkWord
    check result.wordKind == wkSetWord
    check result.wordName == "x"

  test "to lit-word from string":
    let eval = makeEval()
    let result = eval.evalString("to lit-word! \"name\"")
    check result.kind == vkWord
    check result.wordKind == wkLitWord
    check result.wordName == "name"

  test "to get-word from string":
    let eval = makeEval()
    let result = eval.evalString("to get-word! \"print\"")
    check result.kind == vkWord
    check result.wordKind == wkGetWord
    check result.wordName == "print"

  test "to block from string":
    let eval = makeEval()
    let result = eval.evalString("to block! \"hello\"")
    check result.kind == vkBlock
    check result.blockVals.len == 1
    check result.blockVals[0].kind == vkString
    check result.blockVals[0].strVal == "hello"

# =============================================================================
# homoiconic.test.ts — bind
# =============================================================================

suite "Bind":
  test "bind words to context":
    let eval = makeEval()
    discard eval.evalString("point: context [x: 10 y: 20]")
    discard eval.evalString("code: [x + y]")
    discard eval.evalString("bind code point")
    check $eval.evalString("do code") == "30"

  test "bind mutates block":
    let eval = makeEval()
    discard eval.evalString("env: context [a: 99]")
    discard eval.evalString("blk: [a]")
    discard eval.evalString("bind blk env")
    check $eval.evalString("do blk") == "99"

  test "bind does not affect unbound":
    let eval = makeEval()
    discard eval.evalString("env: context [x: 5]")
    discard eval.evalString("y: 10")
    discard eval.evalString("code: [x + y]")
    discard eval.evalString("bind code env")
    check $eval.evalString("do code") == "15"

  test "bind nested blocks":
    let eval = makeEval()
    discard eval.evalString("env: context [n: 42]")
    discard eval.evalString("code: [if true [n]]")
    discard eval.evalString("bind code env")
    check $eval.evalString("do code") == "42"

  test "bind returns block":
    let eval = makeEval()
    discard eval.evalString("env: context [x: 7]")
    check $eval.evalString("do bind [x] env") == "7"

# =============================================================================
# homoiconic.test.ts — words-of
# =============================================================================

suite "Words-of":
  test "context":
    let eval = makeEval()
    discard eval.evalString("env: context [x: 10 y: 20]")
    let result = eval.evalString("words-of env")
    check result.kind == vkBlock
    check result.blockVals.len == 2

# =============================================================================
# homoiconic.test.ts — compose + code generation
# =============================================================================

suite "Compose and code generation":
  test "compose set-word builds code":
    let eval = makeEval()
    discard eval.evalString("field: \"greeting\"")
    discard eval.evalString("code: compose [(to set-word! field) \"hello world\"]")
    discard eval.evalString("do code")
    check $eval.evalString("greeting") == "hello world"

  test "compose generate function":
    let eval = makeEval()
    discard eval.evalString("name: \"double\"")
    discard eval.evalString("code: compose [(to set-word! name) function [x] [x * 2]]")
    discard eval.evalString("do code")
    check $eval.evalString("double 21") == "42"

  test "bind do scoped execution":
    let eval = makeEval()
    discard eval.evalString("math: context [pi: 3.14 tau: 6.28]")
    discard eval.evalString("code: [pi + tau]")
    discard eval.evalString("bind code math")
    check $eval.evalString("do code") == "9.42"

# =============================================================================
# lifecycle.test.ts — @enter / @exit hooks
# =============================================================================

suite "Lifecycle hooks":
  test "lifecycle enter before body":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("""
      if true [
        @enter [print "enter"]
        print "body"
      ]
    """)
    check eval.output == @["enter", "body"]

  test "lifecycle exit after body":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("""
      if true [
        print "body"
        @exit [print "exit"]
      ]
    """)
    check eval.output == @["body", "exit"]

  test "lifecycle enter and exit":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("""
      if true [
        @enter [print "enter"]
        @exit [print "exit"]
        print "body"
      ]
    """)
    check eval.output == @["enter", "body", "exit"]

  test "lifecycle exit on error":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("""
      result: try [
        @enter [print "enter"]
        @exit [print "exit"]
        error 'fail "boom" none
      ]
    """)
    check eval.output == @["enter", "exit"]
    check $eval.evalString("result/ok") == "false"

  test "lifecycle exit sees bindings":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("""
      if true [
        @exit [print x]
        x: 42
      ]
    """)
    check eval.output == @["42"]

# =============================================================================
# Additional spec-driven tests
# =============================================================================

suite "Truthiness":
  test "zero is truthy":
    let eval = makeEval()
    check $eval.evalString("if 0 [true]") == "true"

  test "empty string truthy":
    let eval = makeEval()
    check $eval.evalString("if \"\" [true]") == "true"

  test "empty block truthy":
    let eval = makeEval()
    check $eval.evalString("if [] [true]") == "true"

  test "none is falsy":
    let eval = makeEval()
    check $eval.evalString("if none [true]") == "none"

  test "false is falsy":
    let eval = makeEval()
    check $eval.evalString("if false [true]") == "none"

suite "Equality":
  test "block structural":
    let eval = makeEval()
    check $eval.evalString("[1 2 3] = [1 2 3]") == "true"

  test "block nested":
    let eval = makeEval()
    check $eval.evalString("[1 [2 3]] = [1 [2 3]]") == "true"

  test "numeric cross type":
    let eval = makeEval()
    check $eval.evalString("42 = 42.0") == "true"

  test "none only none":
    let eval = makeEval()
    check $eval.evalString("none = none") == "true"
    check $eval.evalString("none = false") == "false"

  test "string case sensitive":
    let eval = makeEval()
    check $eval.evalString("\"abc\" = \"ABC\"") == "false"

  test "money not number":
    let eval = makeEval()
    check $eval.evalString("$42.00 = 42") == "false"

  test "cross type false":
    let eval = makeEval()
    check $eval.evalString("1 = \"1\"") == "false"
    check $eval.evalString("true = 1") == "false"

suite "Size and length":
  test "size? canonical":
    let eval = makeEval()
    check $eval.evalString("size? [1 2 3]") == "3"

  test "length? alias":
    let eval = makeEval()
    check $eval.evalString("length? [1 2 3]") == "3"

suite "Logic operators":
  test "and basic":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("x: false and true")
    check $eval.evalString("x") == "false"

  test "or first true":
    let eval = makeEval()
    check $eval.evalString("true or false") == "true"

  test "and both true":
    let eval = makeEval()
    check $eval.evalString("true and true") == "true"

  test "and first false":
    let eval = makeEval()
    check $eval.evalString("false and true") == "false"

  test "or first false":
    let eval = makeEval()
    check $eval.evalString("false or true") == "true"

  test "or both false":
    let eval = makeEval()
    check $eval.evalString("false or false") == "false"

suite "Loop":
  test "vars scoped":
    let eval = makeEval()
    discard eval.evalString("x: 99")
    discard eval.evalString("loop [for [x] from 1 to 3 do [x]]")
    check $eval.evalString("x") == "99"  # loop var doesn't leak

  test "from to":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("loop [for [x] from 1 to 5 do [print x]]")
    check eval.output == @["1", "2", "3", "4", "5"]

  test "for in":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("""loop [for [item] in ["a" "b" "c"] do [print item]]""")
    check eval.output == @["a", "b", "c"]

  test "with break":
    let eval = makeEval()
    eval.clearOutput
    discard eval.evalString("loop [for [x] from 1 to 10 do [if x = 4 [break] print x]]")
    check eval.output == @["1", "2", "3"]

suite "Control flow":
  test "if":
    let eval = makeEval()
    check $eval.evalString("if true [42]") == "42"
    check $eval.evalString("if false [42]") == "none"

  test "either":
    let eval = makeEval()
    check $eval.evalString("either true [1] [2]") == "1"
    check $eval.evalString("either false [1] [2]") == "2"

  test "early return":
    let eval = makeEval()
    discard eval.evalString("clamp: function [val lo hi] [if val < lo [return lo] if val > hi [return hi] val]")
    check $eval.evalString("clamp 5 1 10") == "5"
    check $eval.evalString("clamp -1 1 10") == "1"
    check $eval.evalString("clamp 15 1 10") == "10"

suite "Money":
  test "literal":
    let eval = makeEval()
    check $eval.evalString("$19.99") == "$19.99"

  test "arithmetic":
    let eval = makeEval()
    check $eval.evalString("$10.00 + $5.50") == "$15.50"
    check $eval.evalString("$10.00 - $3.25") == "$6.75"

suite "Pairs":
  test "literal":
    let eval = makeEval()
    check $eval.evalString("100x200") == "100x200"

  test "arithmetic":
    let eval = makeEval()
    check $eval.evalString("10x20 + 5x10") == "15x30"

suite "Type introspection":
  test "type of integer":
    let eval = makeEval()
    check $eval.evalString("type 42") == "integer!"

  test "type of string":
    let eval = makeEval()
    check $eval.evalString("type \"hello\"") == "string!"

  test "integer predicate":
    let eval = makeEval()
    check $eval.evalString("integer? 42") == "true"

  test "string predicate":
    let eval = makeEval()
    check $eval.evalString("string? \"hello\"") == "true"

  test "none predicate":
    let eval = makeEval()
    check $eval.evalString("none? none") == "true"

suite "To conversion":
  test "integer from string":
    let eval = makeEval()
    check $eval.evalString("to integer! \"42\"") == "42"

  test "float from integer":
    let eval = makeEval()
    check $eval.evalString("to float! 7") == "7.0"

  test "string from integer":
    let eval = makeEval()
    check $eval.evalString("to string! 42") == "42"

suite "Do and reduce":
  test "do block":
    let eval = makeEval()
    check $eval.evalString("do [1 + 2]") == "3"

  test "reduce block":
    let eval = makeEval()
    check $eval.evalString("reduce [1 + 2 3 * 4]") == "[3 12]"

suite "Freeze":
  test "frozen?":
    let eval = makeEval()
    discard eval.evalString("c: context [x: 10]")
    check $eval.evalString("frozen? c") == "false"
    discard eval.evalString("f: freeze c")
    check $eval.evalString("frozen? f") == "true"

suite "String operations":
  test "join":
    let eval = makeEval()
    check $eval.evalString("join \"hello\" \" world\"") == "hello world"

  test "uppercase":
    let eval = makeEval()
    check $eval.evalString("uppercase \"hello\"") == "HELLO"

  test "lowercase":
    let eval = makeEval()
    check $eval.evalString("lowercase \"HELLO\"") == "hello"

  test "trim":
    let eval = makeEval()
    check $eval.evalString("trim \"  hello  \"") == "hello"

suite "Block series operations":
  test "size?":
    let eval = makeEval()
    check $eval.evalString("size? [1 2 3]") == "3"

  test "first":
    let eval = makeEval()
    check $eval.evalString("first [10 20 30]") == "10"

  test "last":
    let eval = makeEval()
    check $eval.evalString("last [10 20 30]") == "30"

  test "pick":
    let eval = makeEval()
    check $eval.evalString("pick [10 20 30] 2") == "20"

  test "empty?":
    let eval = makeEval()
    check $eval.evalString("empty? []") == "true"
    check $eval.evalString("empty? [1]") == "false"

suite "Closures":
  test "capture by reference":
    ## Closures hold a reference to the enclosing context.
    ## They can read parent-scope values through the context chain.
    let eval = makeEval()
    discard eval.evalString("state: context [counter: 0]")
    discard eval.evalString("inc: function [] [state/counter: state/counter + 1]")
    discard eval.evalString("inc")
    discard eval.evalString("inc")
    discard eval.evalString("inc")
    check $eval.evalString("state/counter") == "3"
