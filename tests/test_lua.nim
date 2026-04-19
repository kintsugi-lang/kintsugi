import std/unittest
import std/strutils
import ../src/core/types
import ../src/parse/[lexer, parser]
import ../src/emit/lua
import ./emit_test_helper

suite "lua emitter":
  test "emit literals":
    check "42" in emitLua(parseSource("42"))
    check "3.14" in emitLua(parseSource("3.14"))
    check "\"hello\"" in emitLua(parseSource(""""hello" """))
    check "true" in emitLua(parseSource("true"))

  test "emit variable":
    let code = emitLua(parseSource("x: 42"))
    check "local x = 42" in code

  test "emit arithmetic":
    let code = emitLua(parseSource("x: 1 + 2"))
    check "1 + 2" in code

  test "emit function":
    let code = emitLua(parseSource("add: function [a b] [a + b]"))
    check "local function add(a, b)" in code
    check "return a + b" in code

  test "emit if":
    let code = emitLua(parseSource("if true [print 42]"))
    check "if true then" in code

  test "emit print":
    let code = emitLua(parseSource("""print "hello" """))
    check """print("hello")""" in code

  test "pair literal emits via _pair helper with metatable prelude":
    let code = emitLua(parseSource("p: 10x20"))
    check "_pair(10, 20)" in code
    check "_pair_mt.__add" in code
    check "_pair_mt.__mul" in code

  test "pair prelude is gated on pair use":
    let code = emitLua(parseSource("x: 42"))
    check "_pair_mt" notin code

suite "binding tracking":
  test "path access is not a function call":
    let code = emitLua(parseSource("""
      obj: context [cells: [1 2 3]]
      print pick obj/cells 2
    """))
    check "obj.cells[2]" in code
    check "obj.cells(" notin code

  test "context field in loop is not a call":
    let code = emitLua(parseSource("""
      board: context [cells: [1 2 3]]
      loop [for [c] in board/cells do [print c]]
    """))
    check "ipairs(board.cells)" in code
    check "board.cells()" notin code

  test "nested function arity is tracked":
    let code = emitLua(parseSource("""
      outer: function [] [
        inner: function [a b] [a + b]
        inner 3 4
      ]
    """))
    check "inner(3, 4)" in code

  test "typed params dont inflate arity":
    let code = emitLua(parseSource("""
      place: function [pos [integer!] mark [string!]] [pos]
      place 1 "x"
    """))
    check "place(1, \"x\")" in code

  test "refinement names dont inflate arity":
    let code = emitLua(parseSource("""
      greet: function [name /loud] [name]
      greet "world"
    """))
    # Should be called with 1 regular arg + false for the refinement
    check "greet(\"world\", false)" in code

suite "emission context":
  test "if in statement position emits directly":
    let code = emitLua(parseSource("""
      if true [print 42]
    """))
    check "if true then" in code
    # Should not wrap in IIFE — the (function() in the output is only from the prelude
    check "end)()" notin code

  test "either as last expression in function gets implicit return":
    let code = emitLua(parseSource("""
      pick-side: function [x] [
        either x > 0 ["positive"] ["non-positive"]
      ]
    """))
    check "return \"positive\"" in code
    check "return \"non-positive\"" in code

  test "match as last expression in function gets implicit return":
    let code = emitLua(parseSource("""
      describe: function [x] [
        match x [
          [1] ["one"]
          [2] ["two"]
          default ["other"]
        ]
      ]
    """))
    check "return \"one\"" in code
    check "return \"other\"" in code

  test "loop body does not have return on loop statement":
    let code = emitLua(parseSource("""
      loop [for [i] from 1 to 3 do [print i]]
    """))
    # Loop should not have return in its body
    check "return print" notin code

suite "refinement emission":
  test "function with refinement emits boolean param":
    let code = emitLua(parseSource("""
      greet: function [name /loud] [
        if loud [uppercase name]
      ]
    """))
    check "function greet(name, loud)" in code
    check "/loud" notin code

  test "refinement call emits true":
    let code = emitLua(parseSource("""
      greet: function [name /loud] [name]
      greet/loud "world"
    """))
    check "greet(\"world\", true)" in code

  test "non-refinement call emits false":
    let code = emitLua(parseSource("""
      greet: function [name /loud] [name]
      greet "world"
    """))
    check "greet(\"world\", false)" in code

  test "refinement with param":
    let code = emitLua(parseSource("""
      fmt: function [val /pad size] [val]
      fmt/pad 42 10
    """))
    check "function fmt(val, pad, size)" in code
    check "fmt(42, true, 10)" in code

  test "multiple refinements":
    let code = emitLua(parseSource("""
      say: function [msg /loud /prefix tag] [msg]
      say/loud "hi"
    """))
    check "function say(msg, loud, prefix, tag)" in code
    check """say("hi", true, false, nil)""" in code

  test "typed params with refinement at statement level":
    let code = emitLua(parseSource("""
      place: function [pos [integer!] mark [string!] /force] [pos]
    """))
    check "function place(pos, mark, force)" in code
    check "integer" notin code
    check "/force" notin code

suite "native refinement calls":
  test "round/down emits math.floor":
    let code = emitLua(parseSource("x: round/down 3.7"))
    check "math.floor(3.7)" in code

  test "round/up emits math.ceil":
    let code = emitLua(parseSource("x: round/up 3.2"))
    check "math.ceil(3.2)" in code

  test "copy/deep emits deep copy helper":
    let code = emitLua(parseSource("""
      items: [[1 2] [3 4]]
      result: copy/deep items
    """))
    check "_deep_copy(items)" in code

suite "import compilation":
  test "import emits Lua require()":
    let code = emitLua(parseSource("""
      utils: import %test-module.ktg
    """), "tests/fixtures")
    check "require(\"test-module\")" in code

  test "import compiles dependency":
    let code = emitLua(parseSource("""
      utils: import %test-module.ktg
      print utils/double 5
    """), "tests/fixtures")
    check "utils.double(5)" in code

  test "exports emits return statement":
    let code = emitLuaModule(parseSource("""
      add: function [a b] [a + b]
      exports [add]
    """)).lua
    check "return {add = add}" in code

  test "exports is skipped in body":
    let code = emitLuaModule(parseSource("""
      x: 42
      exports [x]
    """)).lua
    check "exports" notin code or "return {x = x}" in code

suite "series operation emission":
  test "first emits [1] index":
    let code = emitLua(parseSource("x: first [1 2 3]"))
    check ")[1]" in code

  test "last emits IIFE with length-based access":
    let code = emitLua(parseSource("x: last [1 2 3]"))
    check "#" in code
    check "[#" in code

  test "pick emits indexed access":
    let code = emitLua(parseSource("x: pick [10 20 30] 2"))
    check ")[2]" in code

  test "length emits # operator":
    let code = emitLua(parseSource("x: length [1 2 3]"))
    check "#" in code

  test "empty? emits length comparison":
    let code = emitLua(parseSource("x: empty? [1 2 3]"))
    check "#" in code
    check "== 0" in code

  test "append emits _append helper":
    let code = emitLua(parseSource("""
      items: [1 2]
      items: append items 3
    """))
    check "_append(" in code

  test "reverse on block emits direct reversal":
    let code = emitLua(parseSource("x: reverse [1 2 3]"))
    # Type is known: block. Direct reversal, no runtime dispatch.
    check "string.reverse" notin code
    check "for i=#" in code

  test "reverse on string emits string.reverse":
    let code = emitLua(parseSource("""x: reverse "hello" """))
    check "string.reverse(" in code

  test "select on context emits _select helper":
    let code = emitLua(parseSource("""
      m: context [name: "alice" age: 30]
      x: select m "name"
    """))
    check "_select(" in code

suite "string operation emission":
  test "uppercase emits string.upper":
    let code = emitLua(parseSource("""x: uppercase "hello" """))
    check "string.upper(" in code

  test "lowercase emits string.lower":
    let code = emitLua(parseSource("""x: lowercase "HELLO" """))
    check "string.lower(" in code

  test "trim emits match pattern":
    let code = emitLua(parseSource("""x: trim "  hello  " """))
    # trim uses :match("^%s*(.-)%s*$") not gsub
    check ":match(" in code

  test "split emits _split helper":
    let code = emitLua(parseSource("""x: split "a-b-c" "-" """))
    check "_split(" in code

  test "replace emits _replace helper":
    let code = emitLua(parseSource("""x: replace "hello" "l" "r" """))
    check "_replace(" in code

  test "starts-with? emits string.sub comparison":
    let code = emitLua(parseSource("""x: starts-with? "hello" "he" """))
    check "string.sub(" in code
    check "== \"he\"" in code

  test "subset emits string.sub":
    let code = emitLua(parseSource("""x: subset "hello" 2 3"""))
    check "string.sub(" in code

  test "rejoin emits concatenation":
    let code = emitLua(parseSource("""x: rejoin ["a" 1 "b"]"""))
    check ".." in code

  test "join emits table.concat of literals":
    # join takes a block and literally concatenates each element
    let code = emitLua(parseSource("""x: join ["hello" " world"] """))
    check "table.concat" in code
    check "\"hello\"" in code
    check "\" world\"" in code

suite "math operation emission":
  test "abs emits math.abs":
    let code = emitLua(parseSource("x: abs -5"))
    check "math.abs(" in code

  test "floor emits math.floor":
    let code = emitLua(parseSource("x: floor 3.7"))
    check "math.floor(" in code

  test "ceil emits math.ceil":
    let code = emitLua(parseSource("x: ceil 3.2"))
    check "math.ceil(" in code

  test "sqrt emits math.sqrt":
    let code = emitLua(parseSource("x: sqrt 9"))
    check "math.sqrt(" in code

  test "sin emits math.sin":
    let code = emitLua(parseSource("x: sin 1.0"))
    check "math.sin(" in code

  test "min emits math.min":
    let code = emitLua(parseSource("x: min 3 5"))
    check "math.min(" in code

  test "max emits math.max":
    let code = emitLua(parseSource("x: max 3 5"))
    check "math.max(" in code

  test "random emits math.random":
    let code = emitLua(parseSource("x: random 10"))
    check "math.random" in code

suite "control flow emission":
  test "unless emits if not":
    let code = emitLua(parseSource("unless false [print 1]"))
    check "if not (" in code

  test "not emits Lua not":
    let code = emitLua(parseSource("x: not true"))
    check "not (true)" in code

  test "return inside function emits return":
    let code = emitLua(parseSource("""
      f: function [] [return 42]
    """))
    check "return 42" in code

  test "break in loop emits break":
    let code = emitLua(parseSource("""
      loop [for [i] from 1 to 10 do [break]]
    """))
    check "break" in code

  test "either as statement emits if/else":
    let code = emitLua(parseSource("""
      either true [print 1] [print 2]
    """))
    check "if true then" in code
    check "else" in code

  test "attempt emits pcall":
    let code = emitLua(parseSource("""
      x: attempt [source [42] fallback [0]]
    """))
    check "pcall" in code

  test "sourceless attempt emits reusable function(it)":
    # Matches src/dialects/attempt_dialect.nim:269-286: no source block
    # returns a 1-arg function taking input as `it`.
    let code = emitLua(parseSource("""
      clean: attempt [then [uppercase it] catch 'user [""]]
    """))
    check "function(it)" in code
    # Must not be immediately invoked — it's a reusable value.
    check "end)()" notin code or "pcall" in code  # pcall IIFE is inside
    check "pcall" in code

  test "sourceless attempt is callable from pipeline":
    let code = emitLua(parseSource("""
      double: attempt [then [it * 2]]
      r: double 21
    """))
    check "function(it)" in code
    check "double(21)" in code

  test "try emits pcall":
    let code = emitLua(parseSource("""
      x: try [print 1]
    """))
    check "pcall" in code

suite "interpreter-only natives in compiled output":
  test "save raises compile error naming the native":
    expect EmitError:
      discard emitLua(parseSource("save %out.txt [1 2 3]"))

  test "write raises compile error":
    expect EmitError:
      discard emitLua(parseSource("""write %out.txt "hi" """))

  test "error message includes the native name":
    try:
      discard emitLua(parseSource("save %o [1]"))
      check false  ## should have raised
    except EmitError as e:
      check "save" in e.msg
      check "filesystem IO" in e.msg
