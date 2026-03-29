## Tests for features built 2026-03-27/28:
## dynamic paths, @const prefix, #[] block splicing, strict equality,
## raw, import (rename from require), refinement syntax

import std/[unittest, strutils]
import ../src/core/types
import ../src/parse/[lexer, parser]
import ../src/eval/[dialect, evaluator, natives]
import ../src/emit/lua
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

# --- Dynamic path indexing ---

suite "dynamic paths":
  test "get via dynamic path":
    let eval = makeEval()
    let r = eval.evalString("""
      items: [10 20 30]
      i: 2
      items/:i
    """)
    check $r == "20"

  test "set via dynamic path":
    let eval = makeEval()
    discard eval.evalString("""
      items: [10 20 30]
      i: 2
      items/:i: 99
    """)
    check $eval.evalString("items/:i") == "99"
    check $eval.evalString("items") == "[10 99 30]"

  test "nested context with dynamic path":
    let eval = makeEval()
    let r = eval.evalString("""
      board: context [cells: [1 2 3]]
      pos: 3
      board/cells/:pos
    """)
    check $r == "3"

  test "dynamic path out of range errors":
    let eval = makeEval()
    discard eval.evalString("items: [1 2 3]")
    discard eval.evalString("i: 5")
    discard eval.evalString("result: try [items/:i]")
    check $eval.evalString("result/ok") == "false"

  test "dynamic path compiles to bracket access":
    let code = emitLua(parseSource("""
      items: [1 2 3]
      i: 2
      print items/:i
    """))
    check "items[i]" in code

# --- @const prefix ---

suite "@const prefix":
  test "@const binds value":
    let eval = makeEval()
    let r = eval.evalString("""
      @const x: 42
      x
    """)
    check $r == "42"

  test "@const compiles with <const> annotation":
    let code = emitLua(parseSource("""
      @const x: 42
    """))
    check "local x <const> = 42" in code

  test "old syntax x: @const does not work":
    let eval = makeEval()
    let r = eval.evalString("""
      x: @const
      type x
    """)
    # @const without set-word returns the meta-word itself
    check $r == "meta-word!"

# --- #[] block splicing ---

suite "inline preprocess block splicing":
  test "single value splice":
    let eval = makeEval()
    let r = eval.evalString("""
      x: #[1 + 2]
      x
    """)
    check $r == "3"

  test "block result splices contents":
    let eval = makeEval()
    let r = eval.evalString("""
      #[compose [(to set-word! "my-var") 42]]
      my-var
    """)
    check $r == "42"

  test "block splice generates function":
    let eval = makeEval()
    let r = eval.evalString("""
      #[compose [(to set-word! "dbl") function [x] [x * 2]]]
      dbl 5
    """)
    check $r == "10"

  test "#preprocess only (not @preprocess)":
    let eval = makeEval()
    # @preprocess should NOT trigger preprocessing
    let r = eval.evalString("""
      @preprocess
    """)
    check r.kind == vkWord

# --- Strict equality ---

suite "strict equality ==":
  test "same type same value":
    let eval = makeEval()
    check $eval.evalString("1 == 1") == "true"
    check $eval.evalString(""""hello" == "hello" """) == "true"

  test "cross-type numeric is false":
    let eval = makeEval()
    check $eval.evalString("1 == 1.0") == "false"

  test "loose = still works cross-type":
    let eval = makeEval()
    check $eval.evalString("1 = 1.0") == "true"

  test "different types always false":
    let eval = makeEval()
    check $eval.evalString("""1 == "1" """) == "false"

  test "none == none":
    let eval = makeEval()
    check $eval.evalString("none == none") == "true"

  test "== on non-scalar errors":
    let eval = makeEval()
    discard eval.evalString("result: try [[1 2] == [1 2]]")
    check $eval.evalString("result/ok") == "false"

  test "== compiles to Lua ==":
    let code = emitLua(parseSource("x: 1 == 1"))
    check "1 == 1" in code

# --- raw ---

suite "raw":
  test "raw is no-op in interpreter":
    let eval = makeEval()
    discard eval.evalString("""raw {some lua code}""")
    let r = eval.evalString("42")
    check $r == "42"

  test "raw writes verbatim in compiled output":
    let code = emitLua(parseSource("""
      raw {import "CoreLibs/graphics"}
      x: 42
    """))
    check """import "CoreLibs/graphics"""" in code
    check "local x = 42" in code

  test "raw at statement level":
    let code = emitLua(parseSource("""
      raw {-- this is a lua comment}
    """))
    check "-- this is a lua comment" in code

# --- import (renamed from require) ---

suite "import":
  test "import loads module in interpreter":
    let eval = makeEval()
    discard eval.evalString("""
      m: import %tests/fixtures/test-module.ktg
    """)
    check $eval.evalString("m/double 5") == "10"
    check $eval.evalString("m/triple 3") == "9"

  test "import caches modules":
    let eval = makeEval()
    discard eval.evalString("""
      a: import %tests/fixtures/test-module.ktg
      b: import %tests/fixtures/test-module.ktg
    """)
    # Same object (cached)
    check $eval.evalString("a/double 1") == "2"
    check $eval.evalString("b/double 1") == "2"

  test "import compiles to Lua require":
    let code = emitLua(parseSource("""
      utils: import %test-module.ktg
    """), "tests/fixtures")
    check """require("test-module")""" in code

# --- Refinement syntax ---

suite "refinement lexer":
  test "/name lexes as single token":
    let eval = makeEval()
    let r = eval.evalString("""
      greet: function [name /loud] [
        if loud [uppercase name]
      ]
      greet/loud "world"
    """)
    check $r == "WORLD"

  test "space / name does not create refinement":
    let eval = makeEval()
    # / loud with space: / is division, loud is separate
    # function [name / loud] — this should fail or misbehave
    # because / is an op and loud becomes a regular param
    discard eval.evalString("""
      result: try [
        f: function [name / loud] [name]
        f "test"
      ]
    """)
    # Should either error or not work as refinement
    check $eval.evalString("result/ok") == "false"

# --- = none compilation ---

suite "none comparison compilation":
  test "= none compiles to _is_none":
    let code = emitLua(parseSource("""
      x: 42
      if x = none [print "nil"]
    """))
    check "_is_none(x)" in code
    check "x == nil" notin code

  test "<> none compiles to not _is_none":
    let code = emitLua(parseSource("""
      x: 42
      if x <> none [print "exists"]
    """))
    check "not _is_none(x)" in code

# --- Math/trig ---

suite "trig functions":
  test "sin":
    let eval = makeEval()
    check $eval.evalString("sin 0") == "0.0"

  test "cos":
    let eval = makeEval()
    check $eval.evalString("cos 0") == "1.0"

  test "tan":
    let eval = makeEval()
    check $eval.evalString("tan 0") == "0.0"

  test "asin round-trip":
    let eval = makeEval()
    let r = eval.evalString("sin asin 0.5")
    check r.kind == vkFloat
    check abs(r.floatVal - 0.5) < 0.0001

  test "atan2":
    let eval = makeEval()
    let r = eval.evalString("atan2 1 1")
    check r.kind == vkFloat

suite "pow and logarithms":
  test "pow integer result":
    let eval = makeEval()
    check $eval.evalString("pow 2 10") == "1024"

  test "pow float result":
    let eval = makeEval()
    check $eval.evalString("pow 2 0.5") == "1.4142135623730951"

  test "exp and log round-trip":
    let eval = makeEval()
    let r = eval.evalString("log (exp 1)")
    check r.kind == vkFloat
    check abs(r.floatVal - 1.0) < 0.0001

  test "log10":
    let eval = makeEval()
    check $eval.evalString("log10 100") == "2.0"

suite "floor ceil degrees":
  test "floor":
    let eval = makeEval()
    check $eval.evalString("floor 3.7") == "3"

  test "ceil":
    let eval = makeEval()
    check $eval.evalString("ceil 3.2") == "4"

  test "to-degrees":
    let eval = makeEval()
    check $eval.evalString("to-degrees pi") == "180.0"

  test "to-radians":
    let eval = makeEval()
    let r = eval.evalString("to-radians 180")
    check abs(r.floatVal - 3.14159265) < 0.001

  test "pi constant":
    let eval = makeEval()
    let r = eval.evalString("pi")
    check abs(r.floatVal - 3.14159265) < 0.001

suite "random":
  test "random float in range":
    let eval = makeEval()
    discard eval.evalString("random/seed 42")
    let r = eval.evalString("random 1.0")
    check r.kind == vkFloat
    check r.floatVal >= 0.0
    check r.floatVal < 1.0

  test "random/int":
    let eval = makeEval()
    discard eval.evalString("random/seed 42")
    let r = eval.evalString("random/int 100")
    check r.kind == vkInteger
    check r.intVal >= 0
    check r.intVal < 100

  test "random/choice":
    let eval = makeEval()
    discard eval.evalString("random/seed 42")
    let r = eval.evalString("random/choice [10 20 30]")
    check r.kind == vkInteger
    check r.intVal in [10'i64, 20, 30]

  test "random/seed is deterministic":
    let eval = makeEval()
    discard eval.evalString("random/seed 99")
    let a = eval.evalString("random/int 1000")
    discard eval.evalString("random/seed 99")
    let b = eval.evalString("random/int 1000")
    check $a == $b

  test "random/range float":
    let eval = makeEval()
    discard eval.evalString("random/seed 42")
    let r = eval.evalString("random/range 5.0 10.0")
    check r.kind == vkFloat
    check r.floatVal >= 5.0
    check r.floatVal < 10.0

  test "random/int/range":
    let eval = makeEval()
    discard eval.evalString("random/seed 42")
    let r = eval.evalString("random/int/range 1 6")
    check r.kind == vkInteger
    check r.intVal >= 1
    check r.intVal <= 6

suite "unified series operations":
  test "find on block":
    let eval = makeEval()
    check $eval.evalString("find [10 20 30] 20") == "2"
    check $eval.evalString("find [10 20 30] 99") == "none"

  test "find on string":
    let eval = makeEval()
    check $eval.evalString("""find "hello world" "world" """) == "7"
    check $eval.evalString("""find "hello" "xyz" """) == "none"

  test "reverse block":
    let eval = makeEval()
    check $eval.evalString("reverse [1 2 3]") == "[3 2 1]"

  test "reverse string":
    let eval = makeEval()
    check $eval.evalString("""reverse "hello" """) == "olleh"

  test "append string":
    let eval = makeEval()
    discard eval.evalString("""s: "hello" """)
    discard eval.evalString("""append s " world" """)
    check $eval.evalString("s") == "hello world"

  test "append string mutates in place":
    let eval = makeEval()
    discard eval.evalString("""
      s: "abc"
      append s "d"
      append s "e"
    """)
    check $eval.evalString("s") == "abcde"

suite "filesystem":
  test "dir? on existing directory":
    let eval = makeEval()
    check $eval.evalString("""dir? "src" """) == "true"

  test "dir? on nonexistent":
    let eval = makeEval()
    check $eval.evalString("""dir? "nonexistent" """) == "false"

  test "file? on existing file":
    let eval = makeEval()
    check $eval.evalString("""file? "kintsugi.nimble" """) == "true"

  test "file? on nonexistent":
    let eval = makeEval()
    check $eval.evalString("""file? "nonexistent" """) == "false"

  test "read-dir returns sorted block of strings":
    let eval = makeEval()
    let r = eval.evalString("""read-dir "lib" """)
    check r.kind == vkBlock
    check r.blockVals.len > 0
    check $r.blockVals[0] == "collections.ktg"

  test "read-dir on nonexistent errors":
    let eval = makeEval()
    discard eval.evalString("""result: try [read-dir "nonexistent"]""")
    check $eval.evalString("result/ok") == "false"

suite "replace refinements":
  test "replace all on string":
    let eval = makeEval()
    check $eval.evalString("""replace "aabaa" "a" "x" """) == "xxbxx"

  test "replace/first on string":
    let eval = makeEval()
    check $eval.evalString("""replace/first "aabaa" "a" "x" """) == "xabaa"

  test "replace all on block":
    let eval = makeEval()
    check $eval.evalString("replace [1 2 3 2 1] 2 99") == "[1 99 3 99 1]"

  test "replace/first on block":
    let eval = makeEval()
    check $eval.evalString("replace/first [1 2 3 2 1] 2 99") == "[1 99 3 2 1]"

  test "replace no match returns original":
    let eval = makeEval()
    check $eval.evalString("""replace "hello" "xyz" "!" """) == "hello"
    check $eval.evalString("replace [1 2 3] 9 0") == "[1 2 3]"

suite "math compilation":
  test "trig compiles to math.*":
    let code = emitLua(parseSource("x: sin pi"))
    check "math.sin(pi)" in code

  test "pow compiles":
    let code = emitLua(parseSource("x: pow 2 10"))
    check "math.pow(2, 10)" in code

  test "floor/ceil compile":
    let code = emitLua(parseSource("x: floor 3.7"))
    check "math.floor(3.7)" in code
