## Hybrid enforcement of custom-type param guards in compiled Lua.
##
## Compile-time: literal args that fail the target type's guard raise
## EmitError with "<param> expects <type>!, got <actual> (<val> fails
## <type>! guard at compile time)". Valid literals compile silently.
##
## Runtime: function bodies emit a guard prologue — a failing call with
## a dynamic arg errors at Lua runtime with the same shape of message
## as the interpreter.

import std/[unittest, osproc, os, strutils, sequtils]
import ../src/eval/[evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect,
                        attempt_dialect, parse_dialect]
import ../src/parse/parser
import ../src/emit/lua
import ./emit_test_helper

proc makeEval(): Evaluator =
  result = newEvaluator()
  result.registerNatives()
  result.registerDialect(newLoopDialect())
  result.registerMatch()
  result.registerObjectDialect()
  result.registerAttempt()
  result.registerParse()

proc compileSrc(src: string, withEval = true): string =
  let eval = makeEval()
  let processed = eval.preprocess(parseSource(src), forCompilation = true)
  if withEval: emitLua(processed, "", eval)
  else: emitLua(processed)

proc luaLines(src: string): seq[string] =
  let eval = makeEval()
  let processed = eval.preprocess(parseSource(src), forCompilation = true)
  let luaCode = emitLua(processed, "", eval)
  let tmpFile = getTempDir() / "kintsugi_guard_test.lua"
  writeFile(tmpFile, luaCode)
  let (output, exitCode) = execCmdEx("luajit " & tmpFile)
  removeFile(tmpFile)
  if exitCode != 0:
    # Non-zero exit means the Lua script errored. Return stdout lines so
    # callers can distinguish "compiled and ran to completion" from
    # "compiled and raised a runtime error". We don't raise here — some
    # tests deliberately assert on the error text.
    return output.strip.splitLines
  output.strip.splitLines.filterIt(it.len > 0)

# ============================================================
# Compile-time enforcement: literal args
# ============================================================

suite "guards: compile-time literal check":
  test "negative literal against @type/where integer! [it > 0]":
    expect EmitError:
      discard compileSrc("""
        positive!: @type/where [integer!] [it > 0]
        f: function [n [positive!]] [n]
        print f -3
      """)

  test "error message names param, type and failing value":
    try:
      discard compileSrc("""
        positive!: @type/where [integer!] [it > 0]
        f: function [n [positive!]] [n]
        print f -3
      """)
      fail()
    except EmitError as e:
      check "n expects" in e.msg
      check "positive!" in e.msg
      check "-3" in e.msg
      check "guard" in e.msg

  test "valid positive literal compiles clean":
    let code = compileSrc("""
      positive!: @type/where [integer!] [it > 0]
      f: function [n [positive!]] [n]
      print f 5
    """)
    check "_positive_p" in code
    check "function " in code  # body emitted

  test "union rule — literal of wrong kind is a compile error":
    expect EmitError:
      discard compileSrc("""
        num-or-str!: @type [integer! | string!]
        f: function [x [num-or-str!]] [x]
        print f true
      """)

  test "union rule — literal of valid kind compiles":
    discard compileSrc("""
      num-or-str!: @type [integer! | string!]
      f: function [x [num-or-str!]] [x]
      print f 42
      print f "ok"
    """)

  test "enum rule — lit-word outside members is a compile error":
    expect EmitError:
      discard compileSrc("""
        dir!: @type/enum ['n | 's | 'e | 'w]
        move: function [d [dir!]] [d]
        print move 'up
      """)

  test "enum rule — valid member compiles":
    discard compileSrc("""
      dir!: @type/enum ['n | 's | 'e | 'w]
      move: function [d [dir!]] [d]
      print move 'n
    """)

  test "where-guarded range — out-of-range compile error":
    expect EmitError:
      discard compileSrc("""
        percent!: @type/where [integer!] [(it >= 0) and (it <= 100)]
        set-pct: function [p [percent!]] [p]
        print set-pct 150
      """)

  test "where-guarded range — in-range compiles":
    discard compileSrc("""
      percent!: @type/where [integer!] [(it >= 0) and (it <= 100)]
      set-pct: function [p [percent!]] [p]
      print set-pct 50
    """)

# ============================================================
# Compile-time enforcement: dynamic args fall through
# ============================================================

suite "guards: dynamic args fall through to runtime":
  test "arg is a variable — no compile error":
    let code = compileSrc("""
      positive!: @type/where [integer!] [it > 0]
      f: function [n [positive!]] [n]
      x: -3
      print f x
    """)
    # Emitted fn must carry the runtime guard prologue.
    check "if not _positive_p(n) then" in code
    check "error(" in code

  test "arg is an expression — no compile error":
    # Infix expression produces a computed value; the emitter can't
    # evaluate it literally, so it defers to the runtime prologue.
    let code = compileSrc("""
      positive!: @type/where [integer!] [it > 0]
      f: function [n [positive!]] [n]
      print f (0 - 3)
    """)
    check "if not _positive_p(n) then" in code

  test "arg is a function result — no compile error":
    let code = compileSrc("""
      positive!: @type/where [integer!] [it > 0]
      g: function [] [-3]
      f: function [n [positive!]] [n]
      print f g
    """)
    check "if not _positive_p(n) then" in code

# ============================================================
# Without an evaluator — union / enum still checked, where passes
# ============================================================

suite "guards: compile-time without evaluator":
  test "union rule still catches wrong-kind literal":
    expect EmitError:
      discard compileSrc("""
        num-or-str!: @type [integer! | string!]
        f: function [x [num-or-str!]] [x]
        print f true
      """, withEval = false)

  test "enum rule still catches out-of-set lit-word":
    expect EmitError:
      discard compileSrc("""
        dir!: @type/enum ['n | 's | 'e | 'w]
        move: function [d [dir!]] [d]
        print move 'up
      """, withEval = false)

  test "where rule defers when evaluator is absent":
    # Without eval, the where-guard body can't run, so compile succeeds
    # and the runtime prologue enforces.
    discard compileSrc("""
      positive!: @type/where [integer!] [it > 0]
      f: function [n [positive!]] [n]
      print f -3
    """, withEval = false)

# ============================================================
# Runtime prologue — LuaJIT end-to-end
# ============================================================

suite "guards: runtime prologue in compiled Lua":
  test "valid call runs cleanly":
    let lines = luaLines("""
      positive!: @type/where [integer!] [it > 0]
      f: function [n [positive!]] [n]
      print f 5
    """)
    check lines == @["5"]

  test "dynamic invalid arg errors at runtime":
    # Variable carries -3; compile time can't prove failure, runtime
    # prologue catches it.
    let lines = luaLines("""
      positive!: @type/where [integer!] [it > 0]
      f: function [n [positive!]] [n]
      x: -3
      print f x
    """)
    let combined = lines.join("\n")
    check "n expects positive!" in combined

  test "union rule — dynamic wrong kind errors at runtime":
    let lines = luaLines("""
      num-or-str!: @type [integer! | string!]
      f: function [x [num-or-str!]] [x]
      flag: true
      print f flag
    """)
    let combined = lines.join("\n")
    check "expects num-or-str!" in combined

# ============================================================
# Untyped params — no guard, no error
# ============================================================

suite "guards: untyped params unaffected":
  test "untyped param accepts anything":
    let code = compileSrc("""
      f: function [n] [n]
      print f -3
    """)
    check "_positive_p" notin code
    check "if not" notin code

  test "primitive-typed param does not emit custom guard":
    # integer! is a primitive, not a custom @type. Primitive enforcement
    # is a separate concern (interpreter checks; compiled mode doesn't).
    # This pass must not spuriously emit a _integer_p guard.
    let code = compileSrc("""
      f: function [n [integer!]] [n]
      print f 5
    """)
    check "_integer_p" notin code
