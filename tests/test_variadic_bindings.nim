## Tests for `'variadic` binding kind and `returns N` multi-return.
##
## A variadic binding declares one argument slot that must be a literal
## block at the call site. The block's contents are spliced into the
## emitted Lua call as positional arguments. Optional `returns N`
## declares Lua multi-return; combined with `set [...]` destructure, the
## emitter produces `local a, b, c = path(...)` directly, skipping the
## `_set_tmp` indexing path used for generic single-return RHS.

import std/unittest
import std/strutils
import ../src/core/types
import ../src/parse/parser
import ../src/emit/lua
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/loop_dialect
import ./emit_test_helper

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval

suite "variadic bindings: emit":
  test "splices block contents into Lua call":
    let code = emitLua(parseSource("""
      Kintsugi []
      bindings [
        print-all "print" 'variadic
      ]
      print-all ["hi" 10 20]
    """))
    check "print(\"hi\", 10, 20)" in code

  test "empty block is zero-arg call":
    let code = emitLua(parseSource("""
      Kintsugi []
      bindings [
        quit "os.exit" 'variadic
      ]
      quit []
    """))
    check "os.exit()" in code

  test "word references inside block splice as identifiers":
    let code = emitLua(parseSource("""
      Kintsugi []
      bindings [
        rect "love.graphics.rectangle" 'variadic
      ]
      x: 10  y: 20  w: 50  h: 80
      rect ["fill" x y w h]
    """))
    check "love.graphics.rectangle(\"fill\", x, y, w, h)" in code

  test "paren-wrapped sub-expression becomes a single arg":
    # Parens in the block form grouped sub-expressions in the emitted
    # Lua. The grouping is preserved (defensive parenthesization from
    # emitExpr), which is semantically identical and keeps infix
    # precedence safe even though Lua has operator precedence.
    let code = emitLua(parseSource("""
      Kintsugi []
      bindings [
        rect "love.graphics.rectangle" 'variadic
      ]
      x: 10  w: 50
      rect ["fill" (x + 5) w (w * 2) 100]
    """))
    check "love.graphics.rectangle(\"fill\", (x + 5), w, (w * 2), 100)" in code

  test "nested variadic call in outer block":
    let code = emitLua(parseSource("""
      Kintsugi []
      bindings [
        outer "outer.call" 'variadic
        inner "inner.call" 'variadic
      ]
      outer ["a" (inner [1 2]) "b"]
    """))
    check "outer.call(\"a\", inner.call(1, 2), \"b\")" in code

  test "path-form variadic splices at both expression and statement positions":
    # `lg/rectangle` is a path binding (head + segment). Prior to the path
    # branch learning about bkVariadic, the block argument was emitted as
    # a Lua table literal wrapping the whole arg list, producing
    # `lg.rectangle({...})` instead of `lg.rectangle(...)`.
    let code = emitLua(parseSource("""
      Kintsugi []
      bindings [
        lg         "love.graphics"          'alias
        lg/print   "love.graphics.print"    'variadic
      ]
      x: 10
      lg/print ["hello" x 20]
    """))
    check "lg.print(\"hello\", x, 20)" in code
    check "{\"hello\"" notin code

  test "variadic binding at statement position":
    let code = emitLua(parseSource("""
      Kintsugi []
      bindings [
        log "io.write" 'variadic
      ]
      log ["starting\n"]
      log ["done\n"]
    """))
    check "io.write(\"starting\\n\")" in code
    check "io.write(\"done\\n\")" in code

  test "non-block arg to variadic binding raises compile error":
    expect EmitError:
      discard emitLua(parseSource("""
        Kintsugi []
        bindings [
          foo "foo" 'variadic
        ]
        args: [1 2 3]
        foo args
      """))

suite "variadic bindings: returns (multi-return)":
  test "returns N destructures directly into local multi-assign":
    let code = emitLua(parseSource("""
      Kintsugi []
      bindings [
        rgb-bytes "love.math.colorFromBytes" 'variadic returns 3
      ]
      set [r g b] rgb-bytes [255 128 0]
    """))
    check "local r, g, b = love.math.colorFromBytes(255, 128, 0)" in code
    check "_set_tmp" notin code

  test "returns 1 is the default and emits single assignment":
    let code = emitLua(parseSource("""
      Kintsugi []
      bindings [
        now "os.time" 'variadic
      ]
      t: now []
    """))
    check "local t = os.time()" in code

  test "multi-return used in non-tail position still emits direct call":
    # The Lua semantics (truncate to 1 when not tail) is the caller's
    # responsibility to reason about. Emitter just emits the call.
    let code = emitLua(parseSource("""
      Kintsugi []
      bindings [
        rgb-bytes "love.math.colorFromBytes" 'variadic returns 3
        set-color "love.graphics.setColor" 'variadic
      ]
      set-color [(rgb-bytes [255 0 0])]
    """))
    check "love.graphics.setColor(love.math.colorFromBytes(255, 0, 0))" in code

suite "variadic bindings: interpreter":
  test "variadic binding registers as placeholder returning none":
    let eval = makeEval()
    discard eval.evalString("""
      bindings [foo "foo" 'variadic]
    """)
    # Placeholder returns none regardless of arg; body must not error.
    check $eval.evalString("foo [1 2 3]") == "none"

  test "variadic returns N placeholder returns a block of N nones":
    let eval = makeEval()
    discard eval.evalString("""
      bindings [rgb-bytes "rgb" 'variadic returns 3]
    """)
    # Destructure works in interpreter because placeholder returns a
    # block of N none values.
    discard eval.evalString("set [r g b] rgb-bytes [255 0 0]")
    check $eval.evalString("r") == "none"
    check $eval.evalString("g") == "none"
    check $eval.evalString("b") == "none"
