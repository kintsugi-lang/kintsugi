import std/unittest
import std/strutils
import ../src/core/types
import ../src/parse/[lexer, parser]
import ../src/emit/lua

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
    check "local x = 1 + 2" in code

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
  test "if in expression position wraps in IIFE":
    let code = emitLua(parseSource("""
      x: if true [42]
    """))
    check "function()" in code
    check "local x" in code

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
          default: ["other"]
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
    """))
    check "return {add = add}" in code

  test "exports is skipped in body":
    let code = emitLuaModule(parseSource("""
      x: 42
      exports [x]
    """))
    check "exports" notin code or "return {x = x}" in code

suite "tic-tac-toe compilation":
  test "graphical main compiles without known bug patterns":
    let source = readFile("examples/tic-tac-toe/graphical/main.ktg")
    let code = emitLua(parseSource(source))
    # B1/B2/B3: no spurious () on value access
    check "board.cells()" notin code
    check "state.full()" notin code
    check "state.choice()" notin code
    # Correct patterns
    check "board.cells" in code
    check "ipairs(board.cells)" in code
    check "function cell_at(pos)" in code
    check "board.cells[pos]" in code

  test "terminal main compiles without known bug patterns":
    let source = readFile("examples/tic-tac-toe/terminal/main.ktg")
    let code = emitLua(parseSource(source))
    check "board.cells()" notin code
    check "board.cells" in code
