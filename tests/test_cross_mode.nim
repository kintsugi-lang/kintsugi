## Cross-mode tests: verify interpreter and compiler produce identical results.
## Each test runs the same Kintsugi code through both paths and compares output.
## Compiler output is executed via luajit (Lua 5.1 compatible, no GUI).
##
## Known remaining gaps NOT tested here:
##   - `none` prints as "nil" in Lua (no _NONE sentinel for print)
##   - Dynamic arity: return values used as functions (requires type flow analysis)
##   - Float display: LuaJIT prints `4` for `4.0`

import std/[unittest, osproc, os, strutils, sequtils]
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]
import ../src/parse/parser
import ../src/emit/lua

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerObjectDialect()
  eval.registerAttempt()
  eval.registerParse()
  eval

proc interpOutput(src: string): seq[string] =
  ## Run through interpreter, return captured print output.
  let eval = makeEval()
  discard eval.evalString(src)
  eval.output

proc compileOutput(src: string): seq[string] =
  ## Compile to Lua, run via luajit, return stdout lines.
  let eval = makeEval()
  let processed = eval.preprocess(parseSource(src), forCompilation = true)
  let luaCode = emitLua(processed)
  let tmpFile = getTempDir() / "kintsugi_cross_mode.lua"
  writeFile(tmpFile, luaCode)
  let (output, exitCode) = execCmdEx("luajit " & tmpFile)
  removeFile(tmpFile)
  if exitCode != 0:
    raise newException(CatchableError,
      "luajit exited with " & $exitCode & ":\n" & output &
      "\n--- Lua source ---\n" & luaCode)
  output.strip.splitLines.filterIt(it.len > 0)

proc crossCheck(src: string) =
  ## Assert interpreter and compiler produce identical print output.
  let interp = interpOutput(src)
  let compiled = compileOutput(src)
  if interp != compiled:
    checkpoint("Kintsugi source: " & src)
    checkpoint("Interpreter output: " & $interp)
    checkpoint("Compiler output:    " & $compiled)
    fail()

# ============================================================
# Arithmetic (integers only — floats have display differences)
# ============================================================

suite "cross-mode: arithmetic":
  test "integer ops":
    crossCheck("print 1 + 2")
    crossCheck("print 10 - 3")
    crossCheck("print 4 * 5")
    crossCheck("print 10 / 2")
    crossCheck("print 10 % 3")

  test "string concatenation via rejoin":
    crossCheck("""print rejoin ["hello" " world"] """)

  test "left-to-right evaluation":
    crossCheck("print 2 + 3 * 4")

  test "paren grouping":
    crossCheck("print 2 + (3 * 4)")

# ============================================================
# Comparison and logic
# ============================================================

suite "cross-mode: comparison":
  test "equality":
    crossCheck("print 1 = 1")
    crossCheck("print 1 = 2")
    crossCheck("""print "a" = "a" """)

  test "inequality":
    crossCheck("print 1 <> 2")
    crossCheck("print 1 <> 1")

  test "ordering":
    crossCheck("print 3 > 2")
    crossCheck("print 3 < 2")
    crossCheck("print 3 >= 3")
    crossCheck("print 2 <= 3")

  test "not":
    crossCheck("print not true")
    crossCheck("print not false")

# ============================================================
# Variables and functions
# ============================================================

suite "cross-mode: variables and functions":
  test "assignment and use":
    crossCheck("x: 42\nprint x")

  test "function call":
    crossCheck("add: function [a b] [a + b]\nprint add 3 4")

  test "multi-arg function":
    crossCheck("""
      mul3: function [a b c] [a * b * c]
      print mul3 2 3 4
    """)

  test "function with body":
    crossCheck("""
      classify: function [n] [
        if n > 0 [return "positive"]
        if n < 0 [return "negative"]
        return "zero"
      ]
      print classify 5
      print classify -3
      print classify 0
    """)

# ============================================================
# Control flow
# ============================================================

suite "cross-mode: control flow":
  test "if true":
    crossCheck("if true [print 42]")

  test "if false skips body":
    crossCheck("""
      if false [print 42]
      print "done"
    """)

  test "either":
    crossCheck("""print either true ["yes"] ["no"] """)
    crossCheck("""print either false ["yes"] ["no"] """)

  test "unless":
    crossCheck("""unless false [print "ran"]""")

# ============================================================
# Either edge cases (B4 fix)
# ============================================================

suite "cross-mode: either (B4 fix)":
  test "true branch returns false":
    crossCheck("""print either true [false] [42]""")

  test "false branch returns 42":
    crossCheck("""print either false [false] [42]""")

  test "multi-statement blocks":
    crossCheck("""
      result: either true [
        x: 10
        x + 5
      ] [
        0
      ]
      print result
    """)

# ============================================================
# Series operations (B1, B2 fixes)
# ============================================================

suite "cross-mode: series (B1/B2 fixes)":
  test "length":
    crossCheck("print length [1 2 3]")
    crossCheck("""print length "hello" """)
    crossCheck("print length [10 20 30 40]")

  test "empty?":
    crossCheck("print empty? []")
    crossCheck("print empty? [1]")

  test "first/second/last from variable":
    crossCheck("""
      blk: [10 20 30]
      print first blk
      print second blk
      print last blk
    """)

  test "first/second/last from literal":
    crossCheck("print first [10 20 30]")
    crossCheck("print second [10 20 30]")
    crossCheck("print last [10 20 30]")

  test "pick from literal":
    crossCheck("print pick [10 20 30] 2")

  test "pick from variable":
    crossCheck("""
      blk: [10 20 30]
      print pick blk 2
    """)

  test "has? value scan (B1)":
    crossCheck("print has? [1 2 3] 2")
    crossCheck("print has? [1 2 3] 5")

  test "has? string values (B1)":
    crossCheck("""print has? ["a" "b" "c"] "b" """)
    crossCheck("""print has? ["a" "b" "c"] "z" """)

  test "find in block (B2)":
    crossCheck("""
      blk: [10 20 30]
      print find blk 20
    """)

  test "find in string":
    crossCheck("""print find "hello world" "world" """)

  test "reverse string":
    crossCheck("""print reverse "abc" """)

  test "reverse block from variable":
    crossCheck("""
      a: [1 2 3]
      r: reverse a
      print first r
      print second r
      print last r
    """)

  test "copy block independence (B11)":
    crossCheck("""
      a: [1 2 3]
      b: copy a
      append b 4
      print length a
      print length b
    """)

# ============================================================
# String operations (B3 fix)
# ============================================================

suite "cross-mode: strings (B3 fix)":
  test "join":
    crossCheck("""print join "hello" " world" """)

  test "uppercase / lowercase":
    crossCheck("""print uppercase "hello" """)
    crossCheck("""print lowercase "HELLO" """)

  test "trim":
    crossCheck("""print trim "  hello  " """)

  test "starts-with? / ends-with?":
    crossCheck("""print starts-with? "hello" "hel" """)
    crossCheck("""print ends-with? "hello" "llo" """)
    crossCheck("""print starts-with? "hello" "xyz" """)

  test "replace literal (B3)":
    crossCheck("""print replace "hello world" "world" "there" """)

  test "replace with dot (B3)":
    crossCheck("""print replace "3.14" "." "," """)

  test "replace with pattern chars (B3)":
    crossCheck("""print replace "a+b=c" "+" "-" """)

  test "split":
    crossCheck("""
      parts: split "a,b,c" ","
      print first parts
      print second parts
      print last parts
    """)

# ============================================================
# Select (B5 fix)
# ============================================================

# Note: select cross-mode testing is limited because the interpreter's select
# on flat blocks requires word keys (not string keys), but the compiler erases
# words to strings. The _select helper is still correct for the compiled path.

# ============================================================
# Loop dialect
# ============================================================

suite "cross-mode: loops":
  test "for-in":
    crossCheck("""
      loop [for [x] in [10 20 30] do [print x]]
    """)

  test "from-to":
    crossCheck("""
      loop [for [i] from 1 to 3 do [print i]]
    """)

  test "from-to by step":
    crossCheck("""
      loop [for [i] from 0 to 10 by 5 do [print i]]
    """)

# ============================================================
# Scope
# ============================================================

suite "cross-mode: scope":
  test "scope creates new locals":
    crossCheck("""
      x: 1
      scope [
        x: 2
        print x
      ]
      print x
    """)

# ============================================================
# Match dialect (B14 fix)
# ============================================================

suite "cross-mode: match (B14 fix)":
  test "literal match":
    crossCheck("""
      x: 2
      print match x [
        [1] ["one"]
        [2] ["two"]
        [3] ["three"]
      ]
    """)

  test "default":
    crossCheck("""
      x: 99
      print match x [
        [1] ["one"]
        default ["other"]
      ]
    """)

  test "capture":
    crossCheck("""
      x: 42
      print match x [
        [n] [n + 1]
      ]
    """)

  test "type match":
    crossCheck("""
      print match 42 [
        [string!] ["text"]
        [integer!] ["number"]
      ]
    """)

  test "multi-element destructuring (B14)":
    crossCheck("""
      pair: [1 2]
      print match pair [
        [a b] [a + b]
      ]
    """)

  test "multi-element with literal (B14)":
    crossCheck("""
      v: ["ok" 42]
      print match v [
        ["ok" n] [n]
        ["err" msg] [msg]
      ]
    """)

  test "match as expression":
    crossCheck("""
      x: 2
      result: match x [
        [1] ["one"]
        [2] ["two"]
        default ["other"]
      ]
      print result
    """)

# ============================================================
# Try / error handling
# ============================================================

suite "cross-mode: try":
  test "try success":
    crossCheck("""
      result: try [42]
      print result/ok
      print result/value
    """)

# ============================================================
# String operations
# ============================================================

suite "cross-mode: string operations":
  test "uppercase/lowercase":
    crossCheck("""print uppercase "hello" """)
    crossCheck("""print lowercase "HELLO" """)

  test "trim":
    crossCheck("""print trim "  hello  " """)

  test "starts-with?/ends-with?":
    crossCheck("""print starts-with? "hello" "he" """)
    crossCheck("""print ends-with? "hello" "lo" """)

  test "substring":
    crossCheck("""print substring "hello world" 1 5""")

  test "rejoin":
    crossCheck("""print rejoin ["a" "b" "c"]""")

# ============================================================
# Math operations
# ============================================================

suite "cross-mode: math operations":
  test "abs":
    crossCheck("print abs -5")
    crossCheck("print abs 5")

  test "min/max":
    crossCheck("print min 3 7")
    crossCheck("print max 3 7")

  test "floor/ceil":
    crossCheck("print floor 3.9")
    crossCheck("print ceil 3.1")

  test "negate":
    crossCheck("print negate 5")
    crossCheck("print negate -3")

  test "odd?/even?":
    crossCheck("print odd? 3")
    crossCheck("print even? 4")

# ============================================================
# Contexts and functions
# ============================================================

suite "cross-mode: contexts and functions":
  test "context field access":
    crossCheck("""
      obj: context [x: 42]
      print obj/x
    """)

  test "nested function calls":
    crossCheck("""
      add: function [a b] [a + b]
      double: function [x] [add x x]
      print double 5
    """)

  test "function as argument":
    crossCheck("""
      apply-fn: function [f x] [(f x)]
      double: function [n] [n * 2]
      print apply-fn :double 5
    """)

  test "closure captures outer variable":
    crossCheck("""
      make-adder: function [n] [
        function [x] [x + n]
      ]
      add5: make-adder 5
      print add5 10
    """)

# ============================================================
# Loop refinements
# ============================================================

suite "cross-mode: loop refinements":
  test "loop/collect":
    crossCheck("""
      result: loop/collect [for [x] in [1 2 3] do [x * 2]]
      print first result
      print second result
      print last result
    """)

  test "loop/fold":
    crossCheck("""
      result: loop/fold [for [acc x] in [1 2 3 4 5] do [acc + x]]
      print result
    """)

  test "loop with when guard":
    crossCheck("""
      result: loop/collect [for [x] in [1 2 3 4 5] when [x > 2] do [x]]
      print length result
      print first result
    """)

# ============================================================
# Macros and preprocessing
# ============================================================

suite "cross-mode: macros":
  test "macro expands at compile time":
    crossCheck("""
      @macro unless: function [cond body [block!]] [
        @compose [if not (cond) (body)]
      ]
      unless (3 > 5) [print "yes"]
    """)

  test "macro with compose/deep":
    crossCheck("""
      @macro make-adder: function [n [integer!]] [
        @compose/deep [function [x] [x + (n)]]
      ]
      add5: make-adder 5
      print add5 10
    """)

  test "preprocess generates code":
    crossCheck("""
      @preprocess [
        loop [
          for [n] in [1 2 3] do [
            emit @compose/deep [print (n)]
          ]
        ]
      ]
    """)

  test "inline preprocess":
    crossCheck("""
      val: @inline [2 + 3]
      print val
    """)

  test "preprocess platform is lua when compiling":
    # Interpreter sees 'script, compiler sees 'lua
    # So we test them separately, not crossCheck
    let eval = makeEval()
    discard eval.evalString("""
      @preprocess [
        if system/platform = 'script [emit [print "script"]]
      ]
    """)
    check eval.output == @["script"]

    let compiled = compileOutput("""
      @preprocess [
        if system/platform = 'lua [emit [print "compiled"]]
      ]
    """)
    check compiled == @["compiled"]
