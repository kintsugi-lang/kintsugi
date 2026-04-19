import std/[unittest, os]
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, parse_dialect, object_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerParse()
  eval.registerObjectDialect()
  eval


# --- 1. Pair with negative component ---

suite "lexer: pair with negative component":
  test "100x-200 parses as pair":
    let eval = makeEval()
    let result = eval.evalString("100x-200")
    check result.kind == vkPair
    check result.px == 100
    check result.py == -200

  test "50x-50 parses correctly":
    let eval = makeEval()
    let result = eval.evalString("50x-50")
    check result.kind == vkPair
    check result.px == 50
    check result.py == -50

  test "positive pair still works":
    let eval = makeEval()
    let result = eval.evalString("100x200")
    check result.kind == vkPair
    check result.px == 100
    check result.py == 200

  test "pair with negative component in expression":
    let eval = makeEval()
    let result = eval.evalString("""
      p: 10x-20
      p
    """)
    check result.kind == vkPair
    check result.px == 10
    check result.py == -20


# --- 2. Lit-word match case insensitivity ---

suite "match: lit-word case insensitivity":
  test "lit-word pattern matches same case":
    let eval = makeEval()
    let result = eval.evalString("""
      match 'hello [
        ['hello] [true]
        default [false]
      ]
    """)
    check $result == "true"

  test "lit-word pattern matches different case":
    let eval = makeEval()
    let result = eval.evalString("""
      match 'Hello [
        ['hello] [true]
        default [false]
      ]
    """)
    check $result == "true"

  test "lit-word pattern matches uppercase vs lowercase":
    let eval = makeEval()
    let result = eval.evalString("""
      match 'FOO [
        ['foo] [42]
        default [0]
      ]
    """)
    check $result == "42"


# --- 3. Break inside some/any in parse ---

suite "parse: break exits some/any":
  test "break exits some loop":
    let eval = makeEval()
    let result = eval.evalString("""
      r: @parse "aaab" [some ["a" | "b" break]]
      r/ok
    """)
    check $result == "true"

  test "break exits any loop":
    let eval = makeEval()
    let result = eval.evalString("""
      r: @parse "xxxyz" [any ["x" | "y" break] "z"]
      r/ok
    """)
    check $result == "true"

  test "some without break still works":
    let eval = makeEval()
    let result = eval.evalString("""
      r: @parse "aaa" [some "a"]
      r/ok
    """)
    check $result == "true"


# --- 4. Inline preprocess @inline [expr] ---

suite "inline preprocess @inline [expr]":
  test "@inline [1 + 2] evaluates to 3":
    let eval = makeEval()
    let result = eval.evalString("""
      x: @inline [1 + 2]
      x
    """)
    check $result == "3"

  test "@inline [expression] with string":
    let eval = makeEval()
    let result = eval.evalString("""
      x: @inline [join ["hello" " world"]]
      x
    """)
    check $result == "hello world"


# --- 5. Module isolation ---

suite "module isolation":
  test "module cannot see caller local variables":
    # Create a temp module file that tries to access a variable from the caller
    let tmpDir = getTempDir()
    let modPath = tmpDir / "test_isolation_mod.ktg"
    writeFile(modPath, """
      result: 0
      r: try [
        result: caller-local
      ]
      either none? r/kind [result: caller-local] [result: 0]
      exports [result]
    """)
    defer: removeFile(modPath)

    let eval = makeEval()
    # Set a variable in a function's local scope (not global), then require
    # The module runs in newContext(eval.global), so it should NOT see function locals
    let result = eval.evalString("""
      f: function [] [
        caller-local: 999
        m: import """ & "\"" & modPath & "\"" & """

        m/result
      ]
      f
    """)
    # The module should NOT see caller-local, so result should be 0
    check $result == "0"


# --- 6. load/header ---

suite "load/header":
  test "load/header returns header block":
    let tmpDir = getTempDir()
    let filePath = tmpDir / "test_header.ktg"
    writeFile(filePath, """Kintsugi [
  title: "Test Module"
  version: "1.0"
]
x: 42
""")
    defer: removeFile(filePath)

    let eval = makeEval()
    let result = eval.evalString("load/header \"" & filePath & "\"")
    check result.kind == vkBlock
    # The block should contain: title: "Test Module" version: "1.0"
    check result.blockVals.len >= 4  # title: "..." version: "..."

  test "load/header returns none when no header":
    let tmpDir = getTempDir()
    let filePath = tmpDir / "test_no_header.ktg"
    writeFile(filePath, "x: 42\n")
    defer: removeFile(filePath)

    let eval = makeEval()
    let result = eval.evalString("load/header \"" & filePath & "\"")
    check result.kind == vkNone


# --- 7. load/fresh (via import/fresh) ---

suite "import/fresh bypasses cache":
  test "import/fresh reloads module":
    let tmpDir = getTempDir()
    let modPath = tmpDir / "test_fresh_mod.ktg"

    # First version
    writeFile(modPath, "val: 1\nexports [val]")
    let eval = makeEval()
    let r1 = eval.evalString("m: import \"" & modPath & "\"\nm/val")
    check $r1 == "1"

    # Update the file
    writeFile(modPath, "val: 2\nexports [val]")

    # Regular import returns cached value
    let r2 = eval.evalString("m2: import \"" & modPath & "\"\nm2/val")
    check $r2 == "1"  # cached

    # import/fresh reloads
    let r3 = eval.evalString("m3: import/fresh \"" & modPath & "\"\nm3/val")
    check $r3 == "2"  # fresh load

    removeFile(modPath)
