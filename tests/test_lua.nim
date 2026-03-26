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
