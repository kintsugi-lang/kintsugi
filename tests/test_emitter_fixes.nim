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
    let code = emitLua(parseSource("x: @const 42"))
    check "<const>" in code
    check "= 42" in code

  test "legacy pre-set-word form is a compile error":
    expect EmitError:
      discard emitLua(parseSource("@const x: 42"))

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

suite "emitter: either as rhs of assignment (Bug A)":
  # When `either` is used as the value for a set-word or set-path, the
  # emitter must hoist the assignment into each branch, not leave an
  # orphan target before the if/else.
  #
  # Regression: `ball/dx: either ball/dx > 0 [-1] [1]` was compiling to
  #   ball.dx            -- orphan bare reference
  #   if ball.dx > 0 then
  #     ball.dx = -1
  #   else
  #     ball.dx = 1
  #   end

  test "set-word with either hoists into branches":
    let code = emitLua(parseSource("""
      x: 5
      x: either x > 0 [-1] [1]
    """))
    check "x = -1" in code
    check "x = 1" in code
    # No orphan bare `x` line
    for line in code.splitLines:
      check line.strip != "x"

  test "set-path with either hoists into branches":
    let code = emitLua(parseSource("""
      obj: context [val: 0]
      obj/val: either obj/val > 0 [-1] [1]
    """))
    check "obj.val = -1" in code
    check "obj.val = 1" in code
    for line in code.splitLines:
      check line.strip != "obj.val"

  test "set-path with either using function-call branches":
    # The branches produce values via function calls — must still
    # compose cleanly as assignments.
    let code = emitLua(parseSource("""
      obj: context [val: 0]
      obj/val: either obj/val > 0 [negate obj/val] [obj/val + 1]
    """))
    check "obj.val = -" in code
    check "obj.val = obj.val + 1" in code
    for line in code.splitLines:
      check line.strip != "obj.val"

  test "set-word with match hoists into branches":
    # Same bug shape: orphan target line before hoisted match.
    let code = emitLua(parseSource("""
      k: "hello"
      x: 0
      x: match k [
        ["hello"] [1]
        ["world"] [2]
        default   [0]
      ]
    """))
    check "x = 1" in code
    check "x = 2" in code
    check "x = 0" in code
    for line in code.splitLines:
      check line.strip != "x"

  test "set-path with match hoists into branches":
    let code = emitLua(parseSource("""
      obj: context [val: 0]
      k: "hello"
      obj/val: match k [
        ["hello"] [1]
        ["world"] [2]
        default   [0]
      ]
    """))
    check "obj.val = 1" in code
    check "obj.val = 2" in code
    check "obj.val = 0" in code
    for line in code.splitLines:
      check line.strip != "obj.val"

suite "emitter: write-through scoping from function bodies (Bug B)":
  # Set-words inside a function body should write through to a matching
  # name in the enclosing (module) scope, not create a shadow `local`.
  # Matches the interpreter's write-through semantics from 2026-04-09.
  #
  # Regression: `counter: counter + 1` inside a function was compiling to
  #   local counter = counter + 1
  # which shadows instead of mutating the outer binding.

  test "function body writes through to outer set-word":
    let code = emitLua(parseSource("""
      counter: 0
      bump: function [] [
        counter: counter + 1
      ]
    """))
    check "local counter = 0" in code
    check code.count("local counter") == 1
    check "counter = counter + 1" in code

  test "new name inside function body is still a local":
    # Names that don't exist at outer scope must still emit `local`
    # inside the function — otherwise they'd become globals.
    let code = emitLua(parseSource("""
      compute: function [x] [
        tmp: x * 2
        tmp + 1
      ]
    """))
    check "local tmp = " in code

  test "function param name is a parameter, not a write-through":
    # A parameter with the same name as an outer binding should bind
    # the parameter locally — references inside the body use the param,
    # not the outer value.
    let code = emitLua(parseSource("""
      name: "outer"
      greet: function [name] [
        print name
      ]
    """))
    check "function greet(name)" in code
    # The param `name` shadows the outer. Should not emit `local name` again.
    check code.count("local name") == 1  # only the outer `local name = "outer"`

  test "set-path writes through without local declaration":
    # Set-paths never emit `local` since they can't declare. Sanity check.
    let code = emitLua(parseSource("""
      game: context [score: 0]
      bump: function [] [
        game/score: game/score + 1
      ]
    """))
    check "game.score = game.score + 1" in code
    check "local game.score" notin code

  test "either on set-path inside function writes through":
    # Combines Bug A (either-as-rhs) with Bug B (write-through).
    # The either must hoist into branches AND the set-path must write
    # through without creating a shadow.
    let code = emitLua(parseSource("""
      ball: context [dx: 1]
      flip: function [] [
        ball/dx: either ball/dx > 0 [-1] [1]
      ]
    """))
    check "ball.dx = -1" in code
    check "ball.dx = 1" in code
    for line in code.splitLines:
      check line.strip != "ball.dx"

  test "set-word assignment to outer bool inside function":
    # Exact pong-generated pattern: `paused?: not paused?` inside a
    # keypressed handler, where `paused?` is declared at module scope.
    let code = emitLua(parseSource("""
      paused?: true
      toggle: function [] [
        paused?: not paused?
      ]
    """))
    check "local is_paused = true" in code
    check code.count("local is_paused") == 1
    check "is_paused = not " in code

  test "forward reference: function defined before outer name":
    # Function is defined before the module-level binding it writes to.
    # The write must still thread through — the interpreter's
    # write-through rule looks at the runtime scope chain, not source
    # order.
    let code = emitLua(parseSource("""
      f: function [] [
        counter: counter + 1
      ]
      counter: 0
      f
    """))
    check "local counter = 0" in code
    check code.count("local counter") == 1
    check "counter = counter + 1" in code

suite "emitter: import stdlib modules (Bug C)":
  # The import native resolves stdlib at eval time. Compiler prescan
  # (Task 6) will inline function bodies so the emitter knows arities.
  # Until then, these tests verify the import statement is emitted and
  # the symbol names survive compilation.

  test "import/using math emits clamp reference":
    let code = emitLua(parseSource("import/using 'math [clamp]\nx: clamp 15 0 10\n"))
    check "clamp" in code

  test "import/using collections emits range reference":
    let code = emitLua(parseSource("import/using 'collections [range]\nxs: range 1 5\n"))
    check "range" in code

  test "import with multiple modules emits all references":
    let code = emitLua(parseSource("import/using 'math [clamp]\nimport/using 'collections [range]\nx: clamp 5 0 10\nys: range 1 3\n"))
    check "clamp" in code
    check "range" in code

  test "source without import is unchanged":
    let source = "x: 1 + 2\n"
    let code = emitLua(parseSource(source))
    check "x" in code

suite "emitter: paren preservation for mixed precedence (Bug D)":
  # Kintsugi is left-to-right, no operator precedence. When a paren
  # wraps a mixed-op expression, the parens are load-bearing. Lua *does*
  # have precedence, so the parens must survive translation whenever
  # Lua would otherwise evaluate the inner expression differently.
  #
  # Regression: `(b - a) * t` was compiling to `b - a * t`, which Lua
  # evaluates as `b - (a * t)` because `*` > `-`. Wrong result.

  test "paren around subtraction inside multiplication is preserved":
    let code = emitLua(parseSource("""
      f: function [a b] [(b - a) * 2]
    """))
    check "(b - a) * 2" in code

  test "paren around sum inside multiplication is preserved":
    let code = emitLua(parseSource("""
      area: function [w h border] [(w + h) * border]
    """))
    check "(w + h) * border" in code

  test "lerp compiles correctly":
    # a + ((b - a) * t) — classic case that was silently wrong.
    let code = emitLua(parseSource("""
      lerp: function [a b t] [a + ((b - a) * t)]
    """))
    # Inner (b - a) must survive because it's subtraction inside
    # multiplication. Outer paren around ((b - a) * t) is redundant in
    # Lua (+ and * already have the right precedence) and may or may
    # not be preserved — what matters is the final semantics.
    check "(b - a)" in code
    # Sanity: the compiled expression must equal a + (b - a) * t
    # which Lua evaluates as a + ((b - a) * t) = correct.
    check "a + (b - a) * t" in code or "a + ((b - a) * t)" in code

  test "nested paren with subtraction in mul":
    let code = emitLua(parseSource("""
      f: function [x y z] [((x - y) * (y - z))]
    """))
    check "(x - y) * (y - z)" in code

  test "single-token paren drops parens":
    # `(x)` around a bare variable should not keep parens.
    let code = emitLua(parseSource("""
      f: function [x] [(x) + 1]
    """))
    # Should be `return x + 1`, not `return (x) + 1`
    check "return x + 1" in code

  test "function call paren doesn't add unneeded parens":
    # `(g x)` is a param-call pattern or a head-position call.
    # Shouldn't produce double parens like `((g(x)))`.
    let code = emitLua(parseSource("""
      g: function [n] [n * 2]
      h: function [x] [1 + (g x)]
    """))
    check "((g" notin code
    check "g(x)" in code

# =============================================================================
# @type/guard compileability validation (Step 3 of type-erasure plan)
# =============================================================================

suite "emitter: @type/guard validation":
  test "guard fn with only compileable natives compiles":
    discard emitLua(parseSource("""
      positive?: @type/guard [x] [x > 0]
    """))

  test "guard fn calling another guard fn compiles":
    discard emitLua(parseSource("""
      positive?: @type/guard [x] [x > 0]
      pair-pos?: @type/guard [a b] [(positive? a) (positive? b)]
    """))

  test "guard fn calling interpreter-only native errors":
    expect EmitError:
      discard emitLua(parseSource("""
        bad?: @type/guard [x] [read x]
      """))

  test "guard fn calling non-guard user fn errors":
    expect EmitError:
      discard emitLua(parseSource("""
        helper: function [x] [x + 1]
        bad?: @type/guard [x] [helper x]
      """))

  test "mutually-recursive guard fns validate":
    discard emitLua(parseSource("""
      a?: @type/guard [x] [b? x]
      b?: @type/guard [x] [a? x]
    """))

  test "guard fn allows it and path access":
    discard emitLua(parseSource("""
      pos-x?: @type/guard [pt] [pt/x > 0]
    """))

  test "error message names the offending word":
    try:
      discard emitLua(parseSource("""
        bad?: @type/guard [x] [charset x]
      """))
      check false  # should have raised
    except EmitError as e:
      check "charset" in e.msg
      check "@type/guard" in e.msg
      check "bad?" in e.msg

# =============================================================================
# Synthesized custom-type predicates in prelude (Step 4 of type-erasure plan)
# =============================================================================

suite "emitter: synthesized type predicates":
  test "where-guarded type emits named predicate when used":
    let code = emitLua(parseSource("""
      positive!: @type/where [integer!] [it > 0]
      if is? positive! 5 [print "ok"]
    """))
    check "local function _positive_p(it)" in code
    check "_positive_p(5)" in code

  test "predicate not emitted when not used":
    let code = emitLua(parseSource("""
      positive!: @type/where [integer!] [it > 0]
      print "no usage"
    """))
    check "_positive_p" notin code

  test "union type emits named predicate":
    let code = emitLua(parseSource("""
      sn!: @type [string! | none!]
      if is? sn! "x" [print "yes"]
    """))
    check "local function _sn_p(it)" in code

  test "enum type emits named predicate":
    let code = emitLua(parseSource("""
      dir!: @type/enum ['n | 's | 'e | 'w]
      if is? dir! 'n [print "yes"]
    """))
    check "local function _dir_p(it)" in code
    check "it == \"n\"" in code

  test "transitive composition pulls in dependency predicates":
    let code = emitLua(parseSource("""
      positive!: @type/where [integer!] [it > 0]
      mixed!: @type [positive! | string!]
      if is? mixed! 5 [print "ok"]
    """))
    check "local function _positive_p(it)" in code
    check "local function _mixed_p(it)" in code
    # positive must come before mixed (topological order).
    let posIdx = code.find("_positive_p(it)")
    let mixIdx = code.find("_mixed_p(it)")
    check posIdx >= 0 and mixIdx >= 0
    check posIdx < mixIdx

  test "predicate-call semantics work end-to-end":
    let code = emitLua(parseSource("""
      positive!: @type/where [integer!] [it > 0]
      print is? positive! 5
      print is? positive! -3
    """))
    check "_positive_p(5)" in code
    check "_positive_p(-3)" in code

  test "match pattern on @type routes through synthesized predicate":
    let code = emitLua(parseSource("""
      positive!: @type/where [integer!] [it > 0]
      r: match 5 [
        [positive!] ["yes"]
        [_]         ["no"]
      ]
    """))
    check "_positive_p(5)" in code
    check "local function _positive_p" in code

  test "match pattern on built-in type still uses primitive type check":
    let code = emitLua(parseSource("""
      r: match 5 [
        [integer!] ["yes"]
        [_]        ["no"]
      ]
    """))
    check "type(5) == \"number\"" in code

# =============================================================================
# Clean meta-word emission (Step 6 of type-erasure plan)
# =============================================================================

suite "emitter: meta-word emission":
  test "@type declaration produces no Lua at decl site":
    let code = emitLua(parseSource("""
      positive!: @type/where [integer!] [it > 0]
      print "ok"
    """))
    # No "nil" should appear from the type declaration; no "positive" leakage.
    check "positive!" notin code
    check "= nil" notin code
    check "print(\"ok\")" in code

  test "@type/guard set-word emits a real Lua function":
    let code = emitLua(parseSource("""
      pos?: @type/guard [x] [x > 0]
      print pos? 5
    """))
    check "local function" in code
    check "function" in code
    check "x > 0" in code

  test "@enter at expression position is a compile error":
    expect EmitError:
      discard emitLua(parseSource("""
        @enter [print "x"]
      """))

  test "@exit at expression position is a compile error":
    expect EmitError:
      discard emitLua(parseSource("""
        @exit [print "x"]
      """))

