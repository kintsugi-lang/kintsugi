## Tests for emitter bugs fixed in the audit

import std/unittest
import std/strutils
import ../src/core/types
import ../src/parse/[lexer, parser]
import ../src/emit/lua

suite "emitter: type predicates":
  test "integer? uses floor check":
    let code = emitLua(parseSource("integer? x"))
    check "math.floor" in code
    check "\"number\"" in code

  test "float? uses inverse floor check":
    let code = emitLua(parseSource("float? x"))
    check "math.floor" in code
    check "~=" in code

  test "float? and integer? are mutually exclusive in logic":
    # float? should check floor(x) ~= x (not whole number)
    # integer? should check floor(x) == x (whole number)
    let intCode = emitLua(parseSource("integer? x"))
    let floatCode = emitLua(parseSource("float? x"))
    check "==" in intCode
    check "~=" in floatCode

suite "emitter: split":
  test "split emits _split helper call":
    let code = emitLua(parseSource("""split "hello world" " " """))
    check "_split(" in code

  test "split helper is included in prelude":
    let code = emitLua(parseSource("""split "a,b" "," """))
    check "local function _split" in code
    check "s:find(d, p, true)" in code

suite "emitter: last":
  test "last on simple var emits direct indexing":
    let code = emitLua(parseSource("last x"))
    check "x[#x]" in code

  test "last on complex expr avoids double-eval":
    let code = emitLua(parseSource("last (f 1)"))
    check "local _t" in code

suite "emitter: @const":
  test "const emits <const> annotation":
    let code = emitLua(parseSource("@const x: 42"))
    check "<const>" in code
    check "= 42" in code
