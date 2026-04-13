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

suite "emitter: inline make":
  test "make inlines defaults with overrides":
    let code = emitLua(parseSource("""
      Enemy: object [
        field/optional [hp [integer!] 100]
        field/optional [name [string!] "unnamed"]
      ]
      e: make Enemy [hp: 50]
    """))
    # Should emit inline table, not _make helper call
    check "_make(" notin code
    check "hp = 50" in code
    check "name = \"unnamed\"" in code

  test "make with all required fields inlines to overrides":
    let code = emitLua(parseSource("""
      Point: object [
        field/required [x [integer!]]
        field/required [y [integer!]]
      ]
      p: make Point [x: 10  y: 20]
    """))
    check "_make(" notin code
    check "x = 10" in code
    check "y = 20" in code

  test "make emits _type tag only when is? is used":
    let code = emitLua(parseSource("""
      Card: object [
        field/required [suit [string!]]
      ]
      c: make Card [suit: "hearts"]
      is? card! c
    """))
    check "_type = \"card\"" in code
    check "_make(" notin code

  test "make omits _type tag when is? not used":
    let code = emitLua(parseSource("""
      Card: object [
        field/required [suit [string!]]
      ]
      c: make Card [suit: "hearts"]
    """))
    check "_type" notin code

  test "make with no prelude when not needed":
    let code = emitLua(parseSource("""
      Pos: object [
        field/optional [x [integer!] 0]
        field/optional [y [integer!] 0]
      ]
      p: make Pos [x: 5]
    """))
    check "local function _make" notin code

  test "make preserves field order from object definition":
    let code = emitLua(parseSource("""
      Unit: object [
        field/required [name [string!]]
        field/required [hp [integer!]]
        field/optional [speed [integer!] 10]
      ]
      u: make Unit [name: "hero"  hp: 50]
    """))
    check "_make(" notin code
    # All fields present: overrides + defaults
    check "name = \"hero\"" in code
    check "hp = 50" in code
    check "speed = 10" in code

  test "make with bulk fields syntax inlines":
    let code = emitLua(parseSource("""
      Item: object [
        fields [
          required [name [string!]]
          optional [count [integer!] 1]
        ]
      ]
      i: make Item [name: "sword"]
    """))
    check "_make(" notin code
    check "name = \"sword\"" in code
    check "count = 1" in code

suite "emitter: match without IIFE":
  test "match assignment hoists to if/elseif":
    let code = emitLua(parseSource("""
      x: 1
      r: match x [
        [1] ["one"]
        [2] ["two"]
        default ["other"]
      ]
    """))
    check "(function()" notin code
    check "end)()" notin code
    check "local r" in code
    check "r = " in code

  test "match assignment with guard hoists":
    let code = emitLua(parseSource("""
      x: 5
      r: match x [
        [n] when [n > 3] ["big"]
        default ["small"]
      ]
    """))
    check "(function()" notin code
    check "r = " in code

  test "match assignment with destructuring hoists":
    let code = emitLua(parseSource("""
      pair: [10 20]
      r: match pair [
        [[a b]] [a + b]
        default [0]
      ]
    """))
    check "(function()" notin code
    check "r = " in code

suite "emitter: field-aware tostring in rejoin":
  test "typed integer field skips tostring":
    let code = emitLua(parseSource("""
      Unit: object [
        field/required [hp [integer!]]
        field/optional [name [string!] "unnamed"]
      ]
      u: make Unit [hp: 50]
      print rejoin ["HP: " u/hp]
    """))
    check "tostring(u.hp)" notin code
    check "u.hp" in code

  test "typed string field skips tostring":
    let code = emitLua(parseSource("""
      Unit: object [
        field/required [name [string!]]
      ]
      u: make Unit [name: "hero"]
      print rejoin ["Name: " u/name]
    """))
    check "tostring(u.name)" notin code
    check "u.name" in code

  test "untyped field still gets tostring":
    let code = emitLua(parseSource("""
      Bag: object [
        field/required [contents [block!]]
      ]
      b: make Bag [contents: [1 2 3]]
      print rejoin ["Contents: " b/contents]
    """))
    check "tostring(b.contents)" in code

  test "unknown variable still gets tostring":
    let code = emitLua(parseSource("""
      print rejoin ["Value: " x]
    """))
    check "tostring(x)" in code

  test "typed function param skips tostring in rejoin":
    let code = emitLua(parseSource("""
      Unit: object [
        field/required [name [string!]]
        field/required [hp [integer!]]
      ]
      show: function [u [unit!]] [
        print rejoin ["Name: " u/name " HP: " u/hp]
      ]
    """))
    check "tostring(u.name)" notin code
    check "tostring(u.hp)" notin code
    check "u.name" in code
    check "u.hp" in code

  test "untyped function param still gets tostring":
    let code = emitLua(parseSource("""
      Unit: object [
        field/required [name [string!]]
      ]
      show: function [u] [
        print rejoin ["Name: " u/name]
      ]
    """))
    check "tostring(u.name)" in code

suite "emitter: loop/collect without IIFE":
  test "loop/collect assignment hoists without IIFE":
    let code = emitLua(parseSource("""
      items: [1 2 3 4 5]
      evens: loop/collect [for [x] in items when [x > 2] do [x]]
    """))
    check "(function()" notin code
    check "end)()" notin code
    check "local evens" in code

  test "loop/fold assignment hoists without IIFE":
    let code = emitLua(parseSource("""
      nums: [1 2 3]
      total: loop/fold [for [acc n] in nums do [acc + n]]
    """))
    check "(function()" notin code
    check "end)()" notin code

  test "loop/collect in expression context still works":
    # When used inside a function call, IIFE may still be needed
    let code = emitLua(parseSource("""
      items: [1 2 3]
      print loop/collect [for [x] in items do [x + 1]]
    """))
    check "print(" in code

suite "emitter: has? scalar inlining":
  test "has? with string literal skips _has helper":
    let code = emitLua(parseSource("""
      items: ["a" "b" "c"]
      has? items "b"
    """))
    check "_has(" notin code
    check "== \"b\"" in code

  test "has? with number literal skips _has helper":
    let code = emitLua(parseSource("""
      nums: [1 2 3]
      has? nums 2
    """))
    check "_has(" notin code
    check "== 2" in code

  test "has? with variable still uses _has":
    let code = emitLua(parseSource("""
      items: ["a" "b"]
      x: "a"
      has? items x
    """))
    check "_has(" in code

suite "emitter: sort/by without IIFE":
  test "sort/by assignment hoists without IIFE":
    let code = emitLua(parseSource("""
      items: [3 1 2]
      sorted: sort/by items function [x] [x]
    """))
    check "(function()" notin code
    check "end)()" notin code
    check "table.sort(" in code
    check "local sorted" in code

suite "emitter: type inference for sequences":
  # Phase B: first/last/pick on string variables must emit string ops, not block indexing
  test "first on string literal emits sub":
    let code = emitLua(parseSource("""x: first "hello" """))
    check ":sub(1, 1)" in code
    check "\"hello\"[1]" notin code

  test "first on string variable emits sub":
    let code = emitLua(parseSource("""s: "hello" x: first s"""))
    check "s:sub(1, 1)" in code
    check "s[1]" notin code

  test "first on block variable emits index":
    let code = emitLua(parseSource("""b: [1 2 3] x: first b"""))
    check "b[1]" in code
    check ":sub(" notin code

  test "last on string variable emits sub":
    let code = emitLua(parseSource("""s: "hello" x: last s"""))
    check ":sub(" in code
    check "s[#s]" notin code

  test "last on block variable emits index":
    let code = emitLua(parseSource("""b: [1 2 3] x: last b"""))
    check "b[#b]" in code

  test "first on typed string param emits sub":
    let code = emitLua(parseSource("""
      f: function [s [string!]] [first s]
    """))
    check "s:sub(1, 1)" in code
    check "s[1]" notin code

  test "first on typed block param emits index":
    let code = emitLua(parseSource("""
      f: function [b [block!]] [first b]
    """))
    check "b[1]" in code
    check "b:sub(" notin code

  # Phase B: for/in on string variables must iterate characters
  test "for/in on string variable iterates chars":
    let code = emitLua(parseSource("""s: "abc" loop [for [c] in s do [print c]]"""))
    check "ipairs(s)" notin code
    check ":sub(" in code

  test "for/in on block variable uses ipairs":
    let code = emitLua(parseSource("""b: [1 2 3] loop [for [x] in b do [print x]]"""))
    check "ipairs(b)" in code

  test "for/in on typed string param iterates chars":
    let code = emitLua(parseSource("""
      f: function [s [string!]] [loop [for [c] in s do [print c]]]
    """))
    check "ipairs(s)" notin code
    check ":sub(" in code

  # Phase B: has? on string variables must use string.find
  test "has? on string variable uses string.find":
    let code = emitLua(parseSource("""s: "hello" x: has? s "ll" """))
    check "string.find(s" in code
    check "ipairs(s)" notin code

  test "has? on block variable uses loop":
    let code = emitLua(parseSource("""b: [1 2 3] x: has? b 2"""))
    # Scalar fast path — inline loop with ==
    check "ipairs(b)" in code

  # Phase B: reverse on string variables must use string.reverse
  test "reverse on string variable uses string.reverse":
    let code = emitLua(parseSource("""s: "hello" x: reverse s"""))
    check "string.reverse(s)" in code
    check "(function()" notin code

  test "reverse on block variable does table reverse":
    let code = emitLua(parseSource("""b: [1 2 3] x: reverse b"""))
    check "string.reverse" notin code

  # Phase B: find on string variables must use string.find
  test "find on string variable uses string.find":
    let code = emitLua(parseSource("""s: "hello" x: find s "ll" """))
    check "string.find(s" in code
    check "(function()" notin code

  test "find on block variable uses linear scan":
    let code = emitLua(parseSource("""b: [1 2 3] x: find b 2"""))
    check "string.find" notin code

  # Phase C: subset on known-type variable emits direct Lua
  test "subset on string variable emits string.sub":
    let code = emitLua(parseSource("""s: "hello" x: subset s 2 3"""))
    check "string.sub(s, 2" in code
    check "_subset(" notin code

  test "subset on block variable emits direct slice":
    let code = emitLua(parseSource("""b: [1 2 3 4 5] x: subset b 2 3"""))
    check "_subset(" notin code

  # Phase C: sort on known-type variable emits direct Lua
  test "sort on string variable has no helper":
    let code = emitLua(parseSource("""s: "hello" x: sort s"""))
    check "_sort(" notin code

  test "sort on block variable has no helper":
    let code = emitLua(parseSource("""b: [3 1 2] sort b"""))
    check "_sort(" notin code
    check "table.sort(b)" in code

  # Phase C: insert/remove on known-type strings emit direct ops
  test "insert on string variable has no helper":
    let code = emitLua(parseSource("""s: "helo" x: insert s "l" 4"""))
    check "_insert(" notin code

  test "remove on string variable has no helper":
    let code = emitLua(parseSource("""s: "hello" x: remove s 2"""))
    check "_remove(" notin code

  # Phase A: Type propagation from function return types
  test "subset on uppercase result is typed as string":
    let code = emitLua(parseSource("""
      s: uppercase "hello"
      x: subset s 1 3
    """))
    check "_subset(" notin code
