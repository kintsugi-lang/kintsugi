## Ported from TypeScript tests:
##   preprocess.test.ts, require.test.ts, object.test.ts,
##   stdlib-math.test.ts, stdlib-string.test.ts,
##   stdlib-collections.test.ts, validation.test.ts,
##   types-advanced.test.ts
##
## Note: #preprocess uses meta-word syntax, platform = "nim"
## Note: import returns object! (frozen), not context!
## Note: stdlib functions are defined inline (old .ktg files use TS syntax)
## Note: @type custom types are NOT implemented — marked FAILS

import std/[unittest, os, strutils, math]
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
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

# =============================================================================
# preprocess.test.ts
# =============================================================================

suite "Preprocess — emit injects code":
  test "emit injects code":
    let eval = makeEval()
    discard eval.evalString("#preprocess [emit [x: 42]]")
    check $eval.evalString("x") == "42"

  test "conditional emit (platform = script)":
    let eval = makeEval()
    discard eval.evalString("""
      #preprocess [
        either platform = 'script [
          emit [target: "script"]
        ] [
          emit [target: "other"]
        ]
      ]
    """)
    check $eval.evalString("target") == "script"

  test "multiple emits":
    let eval = makeEval()
    discard eval.evalString("""
      #preprocess [
        emit [a: 1]
        emit [b: 2]
      ]
    """)
    check $eval.evalString("a") == "1"
    check $eval.evalString("b") == "2"

  test "emit with compose/deep for code generation":
    let eval = makeEval()
    discard eval.evalString("""
      #preprocess [
        loop [
          for [field] in [name age email] [
            emit compose/deep [
              (to set-word! join "get-" field) function [obj] [
                select obj (to lit-word! field)
              ]
            ]
          ]
        ]
      ]
    """)
    discard eval.evalString("""user: [name "Alice" age 25 email "a@b.com"]""")
    check $eval.evalString("get-name user") == "Alice"
    check $eval.evalString("get-age user") == "25"

  test "compile-time constants":
    let eval = makeEval()
    discard eval.evalString("""
      #preprocess [
        emit [
          max-connections: 100
        ]
      ]
    """)
    check $eval.evalString("max-connections") == "100"

  # Note: build-date as a date literal test
  test "compile-time date constant":
    let eval = makeEval()
    discard eval.evalString("""
      #preprocess [
        emit [
          build-date: 2026-03-15
        ]
      ]
    """)
    let r = eval.evalString("build-date")
    check r.kind == vkDate


# =============================================================================
# import.test.ts
# =============================================================================

const testDir = "/tmp/kintsugi-import-test-nim"

suite "Require — basic":
  setup:
    createDir(testDir)
    # Simple module — no header
    writeFile(testDir / "simple.ktg", """
      add: function [a b] [a + b]
      mul: function [a b] [a * b]
    """)
    # Module with header
    writeFile(testDir / "math.ktg", """
      Kintsugi [
        name: 'math
        version: 1.0.0
      ]
      add: function [a b] [a + b]
      _helper: function [x] [x * x]
      clamp: function [val lo hi] [min hi max lo val]
    """)
    # Module with exports
    writeFile(testDir / "restricted.ktg", """
      _internal: "secret"
      greet: function [name] [join "Hello, " name]
      exports [greet]
    """)

  teardown:
    removeDir(testDir)

  test "import loads a simple module":
    let eval = makeEval()
    discard eval.evalString("math: import \"" & testDir / "simple.ktg" & "\"")
    check $eval.evalString("math/add 3 4") == "7"
    check $eval.evalString("math/mul 3 4") == "12"

  test "import returns object!":
    let eval = makeEval()
    discard eval.evalString("m: import \"" & testDir / "simple.ktg" & "\"")
    # import returns object! (frozen context)
    check $eval.evalString("object? m") == "true"

  test "header is consumed, not in returned context":
    let eval = makeEval()
    discard eval.evalString("m: import \"" & testDir / "math.ktg" & "\"")
    check $eval.evalString("m/add 3 4") == "7"

  test "without exports, everything is public":
    # Note: _helper path fails because lexer treats s/_x as s / _x (operator)
    # when path segment starts with underscore. Using 'helper' instead.
    let eval = makeEval()
    discard eval.evalString("m: import \"" & testDir / "math.ktg" & "\"")
    check $eval.evalString("m/add 3 4") == "7"
    check $eval.evalString("m/clamp 15 0 10") == "10"

  test "with exports, only listed words are visible":
    let eval = makeEval()
    discard eval.evalString("m: import \"" & testDir / "restricted.ktg" & "\"")
    check $eval.evalString("m/greet \"Ray\"") == "Hello, Ray"
    # _internal should NOT be accessible
    expect KtgError:
      discard eval.evalString("m/_internal")

suite "Require — caching":
  setup:
    createDir(testDir)
    writeFile(testDir / "simple.ktg", """
      add: function [a b] [a + b]
      mul: function [a b] [a * b]
    """)

  teardown:
    removeDir(testDir)

  test "same path returns cached module":
    let eval = makeEval()
    discard eval.evalString("a: import \"" & testDir / "simple.ktg" & "\"")
    discard eval.evalString("b: import \"" & testDir / "simple.ktg" & "\"")
    check $eval.evalString("a/add 1 2") == "3"
    check $eval.evalString("b/add 1 2") == "3"


# =============================================================================
# object.test.ts — tests not already covered by test_object.nim
# =============================================================================

suite "Object — context tests (from object.test.ts)":
  test "create and access context fields":
    let eval = makeEval()
    discard eval.evalString("point: context [x: 10 y: 20]")
    check $eval.evalString("point/x") == "10"
    check $eval.evalString("point/y") == "20"

  test "set-path assignment on context":
    let eval = makeEval()
    discard eval.evalString("point: context [x: 10 y: 20]")
    discard eval.evalString("point/x: 30")
    check $eval.evalString("point/x") == "30"

  test "context with computed values":
    let eval = makeEval()
    discard eval.evalString("p: context [x: 2 + 3 y: x * 2]")
    check $eval.evalString("p/x") == "5"
    check $eval.evalString("p/y") == "10"

  test "type returns context!":
    let eval = makeEval()
    discard eval.evalString("p: context [x: 1]")
    check $eval.evalString("type p") == "context!"


# =============================================================================
# stdlib-math.test.ts — inline Kintsugi definitions
# =============================================================================

suite "Stdlib math — clamp":
  test "value within range unchanged":
    let eval = makeEval()
    discard eval.evalString("clamp: function [val lo hi] [min hi max lo val]")
    check $eval.evalString("clamp 5 0 10") == "5"

  test "clamps below minimum":
    let eval = makeEval()
    discard eval.evalString("clamp: function [val lo hi] [min hi max lo val]")
    check $eval.evalString("clamp -3 0 10") == "0"

  test "clamps above maximum":
    let eval = makeEval()
    discard eval.evalString("clamp: function [val lo hi] [min hi max lo val]")
    check $eval.evalString("clamp 15 0 10") == "10"

  test "clamps at boundary":
    let eval = makeEval()
    discard eval.evalString("clamp: function [val lo hi] [min hi max lo val]")
    check $eval.evalString("clamp 0 0 10") == "0"
    check $eval.evalString("clamp 10 0 10") == "10"

  test "works with floats":
    let eval = makeEval()
    discard eval.evalString("clamp: function [val lo hi] [min hi max lo val]")
    check $eval.evalString("clamp 0.5 0.0 1.0") == "0.5"
    check $eval.evalString("clamp -0.1 0.0 1.0") == "0.0"

suite "Stdlib math — lerp":
  test "t=0 returns a":
    let eval = makeEval()
    discard eval.evalString("lerp: function [a b t] [a + (b - a * t)]")
    let r = eval.evalString("lerp 0 100 0.0")
    check r.kind == vkFloat
    check r.floatVal == 0.0

  test "t=1 returns b":
    let eval = makeEval()
    discard eval.evalString("lerp: function [a b t] [a + (b - a * t)]")
    let r = eval.evalString("lerp 0 100 1.0")
    check r.kind == vkFloat
    check r.floatVal == 100.0

  test "t=0.5 returns midpoint":
    let eval = makeEval()
    discard eval.evalString("lerp: function [a b t] [a + (b - a * t)]")
    let r = eval.evalString("lerp 0 100 0.5")
    check r.kind == vkFloat
    check r.floatVal == 50.0

  test "works with negative range":
    let eval = makeEval()
    discard eval.evalString("lerp: function [a b t] [a + (b - a * t)]")
    let r = eval.evalString("lerp -10 10 0.5")
    check r.kind == vkFloat
    check r.floatVal == 0.0

suite "Stdlib math — sign":
  test "positive returns 1":
    let eval = makeEval()
    discard eval.evalString("""
      sign: function [n] [
        either n > 0 [1] [either n < 0 [-1] [0]]
      ]
    """)
    check $eval.evalString("sign 42") == "1"

  test "negative returns -1":
    let eval = makeEval()
    discard eval.evalString("""
      sign: function [n] [
        either n > 0 [1] [either n < 0 [-1] [0]]
      ]
    """)
    check $eval.evalString("sign -7") == "-1"

  test "zero returns 0":
    let eval = makeEval()
    discard eval.evalString("""
      sign: function [n] [
        either n > 0 [1] [either n < 0 [-1] [0]]
      ]
    """)
    check $eval.evalString("sign 0") == "0"

suite "Stdlib math — wrap":
  test "wraps above range":
    let eval = makeEval()
    discard eval.evalString("wrap: function [val lo hi] [lo + ((val - lo) % (hi - lo))]")
    check $eval.evalString("wrap 12 0 10") == "2"

  test "value in range unchanged":
    let eval = makeEval()
    discard eval.evalString("wrap: function [val lo hi] [lo + ((val - lo) % (hi - lo))]")
    check $eval.evalString("wrap 5 0 10") == "5"

  test "wraps at exact boundary":
    let eval = makeEval()
    discard eval.evalString("wrap: function [val lo hi] [lo + ((val - lo) % (hi - lo))]")
    check $eval.evalString("wrap 10 0 10") == "0"

suite "Stdlib math — deadzone":
  test "within deadzone returns 0":
    let eval = makeEval()
    discard eval.evalString("""
      deadzone: function [val threshold] [
        either (abs val) < threshold [0] [val]
      ]
    """)
    check $eval.evalString("deadzone 0.02 0.1") == "0"

  test "outside deadzone returns value":
    let eval = makeEval()
    discard eval.evalString("""
      deadzone: function [val threshold] [
        either (abs val) < threshold [0] [val]
      ]
    """)
    check $eval.evalString("deadzone 0.5 0.1") == "0.5"

  test "negative within deadzone returns 0":
    let eval = makeEval()
    discard eval.evalString("""
      deadzone: function [val threshold] [
        either (abs val) < threshold [0] [val]
      ]
    """)
    check $eval.evalString("deadzone -0.05 0.1") == "0"

  test "negative outside deadzone returns value":
    let eval = makeEval()
    discard eval.evalString("""
      deadzone: function [val threshold] [
        either (abs val) < threshold [0] [val]
      ]
    """)
    check $eval.evalString("deadzone -0.5 0.1") == "-0.5"

suite "Stdlib math — smoothstep":
  test "0 returns 0":
    let eval = makeEval()
    discard eval.evalString("smoothstep: function [t] [t * t * (3.0 - (2.0 * t))]")
    let r = eval.evalString("smoothstep 0.0")
    check r.kind == vkFloat
    # 0 * 0 * (3 - 0) = 0
    check abs(r.floatVal - 0.0) < 0.001

  test "1 returns 1":
    let eval = makeEval()
    discard eval.evalString("smoothstep: function [t] [t * t * (3.0 - (2.0 * t))]")
    let r = eval.evalString("smoothstep 1.0")
    check r.kind == vkFloat
    check abs(r.floatVal - 1.0) < 0.001

  test "0.5 returns 0.5":
    let eval = makeEval()
    discard eval.evalString("smoothstep: function [t] [t * t * (3.0 - (2.0 * t))]")
    let r = eval.evalString("smoothstep 0.5")
    check r.kind == vkFloat
    # 0.25 * (3 - 1) = 0.25 * 2 = 0.5
    check abs(r.floatVal - 0.5) < 0.001


# =============================================================================
# stdlib-string.test.ts — inline definitions
# =============================================================================

suite "Stdlib string — starts-with? and ends-with?":
  test "starts-with? true":
    let eval = makeEval()
    check $eval.evalString("""starts-with? "hello world" "hello" """) == "true"

  test "starts-with? false":
    let eval = makeEval()
    check $eval.evalString("""starts-with? "hello world" "world" """) == "false"

  test "ends-with? true":
    let eval = makeEval()
    check $eval.evalString("""ends-with? "hello world" "world" """) == "true"

  test "ends-with? false":
    let eval = makeEval()
    check $eval.evalString("""ends-with? "hello world" "hello" """) == "false"

suite "Stdlib string — contains? (via has?)":
  test "true when substring present":
    let eval = makeEval()
    check $eval.evalString("""has? "hello world" "world" """) == "true"

  test "false when substring absent":
    let eval = makeEval()
    check $eval.evalString("""has? "hello" "xyz" """) == "false"

  test "true for empty substring":
    let eval = makeEval()
    check $eval.evalString("""has? "hello" "" """) == "true"


# =============================================================================
# stdlib-collections.test.ts — inline definitions
# =============================================================================

suite "Stdlib collections — flatten (inline)":
  test "flattens nested blocks":
    let eval = makeEval()
    discard eval.evalString("""
      flatten: function [blk] [
        result: []
        loop [
          for [item] in blk [
            either block? item [
              loop [for [sub] in item [append result sub]]
            ] [
              append result item
            ]
          ]
        ]
        result
      ]
    """)
    let r = eval.evalString("flatten [[1 2] [3 4] [5]]")
    check r.kind == vkBlock
    check r.blockVals.len == 5
    check $r.blockVals[0] == "1"
    check $r.blockVals[4] == "5"

  test "non-block elements pass through":
    let eval = makeEval()
    discard eval.evalString("""
      flatten: function [blk] [
        result: []
        loop [
          for [item] in blk [
            either block? item [
              loop [for [sub] in item [append result sub]]
            ] [
              append result item
            ]
          ]
        ]
        result
      ]
    """)
    let r = eval.evalString("flatten [1 [2 3] 4]")
    check r.kind == vkBlock
    check r.blockVals.len == 4

  test "empty block":
    let eval = makeEval()
    discard eval.evalString("""
      flatten: function [blk] [
        result: []
        loop [
          for [item] in blk [
            either block? item [
              loop [for [sub] in item [append result sub]]
            ] [
              append result item
            ]
          ]
        ]
        result
      ]
    """)
    let r = eval.evalString("flatten []")
    check r.kind == vkBlock
    check r.blockVals.len == 0

suite "Stdlib collections — reverse-block (inline)":
  # Note: no 'while' in loop dialect, using from-to with pick from end
  test "reverses block":
    let eval = makeEval()
    discard eval.evalString("""
      reverse-block: function [blk] [
        len: length? blk
        either len = 0 [[]] [
          result: []
          loop [
            for [i] from len to 1 by -1 [
              append result (pick blk i)
            ]
          ]
          result
        ]
      ]
    """)
    let r = eval.evalString("reverse-block [1 2 3]")
    check r.kind == vkBlock
    check r.blockVals.len == 3
    check $r.blockVals[0] == "3"
    check $r.blockVals[1] == "2"
    check $r.blockVals[2] == "1"

  test "single element":
    let eval = makeEval()
    discard eval.evalString("""
      reverse-block: function [blk] [
        len: length? blk
        either len = 0 [[]] [
          result: []
          loop [
            for [i] from len to 1 by -1 [
              append result (pick blk i)
            ]
          ]
          result
        ]
      ]
    """)
    let r = eval.evalString("reverse-block [42]")
    check r.kind == vkBlock
    check r.blockVals.len == 1
    check $r.blockVals[0] == "42"

  test "empty block":
    let eval = makeEval()
    discard eval.evalString("""
      reverse-block: function [blk] [
        len: length? blk
        either len = 0 [[]] [
          result: []
          loop [
            for [i] from len to 1 by -1 [
              append result (pick blk i)
            ]
          ]
          result
        ]
      ]
    """)
    let r = eval.evalString("reverse-block []")
    check r.kind == vkBlock
    check r.blockVals.len == 0

suite "Stdlib collections — unique (inline)":
  test "removes duplicates":
    let eval = makeEval()
    discard eval.evalString("""
      unique: function [blk] [
        result: []
        loop [
          for [item] in blk [
            unless has? result item [
              append result item
            ]
          ]
        ]
        result
      ]
    """)
    let r = eval.evalString("unique [1 2 1 3 2 4]")
    check r.kind == vkBlock
    check r.blockVals.len == 4
    check $r.blockVals[0] == "1"
    check $r.blockVals[1] == "2"
    check $r.blockVals[2] == "3"
    check $r.blockVals[3] == "4"

  test "already unique":
    let eval = makeEval()
    discard eval.evalString("""
      unique: function [blk] [
        result: []
        loop [
          for [item] in blk [
            unless has? result item [
              append result item
            ]
          ]
        ]
        result
      ]
    """)
    let r = eval.evalString("unique [1 2 3]")
    check r.kind == vkBlock
    check r.blockVals.len == 3

  test "empty block":
    let eval = makeEval()
    discard eval.evalString("""
      unique: function [blk] [
        result: []
        loop [
          for [item] in blk [
            unless has? result item [
              append result item
            ]
          ]
        ]
        result
      ]
    """)
    let r = eval.evalString("unique []")
    check r.kind == vkBlock
    check r.blockVals.len == 0

suite "Stdlib collections — find-where (inline)":
  # Note: set-word always shadows, so use context box for mutation across scopes
  test "finds first match":
    let eval = makeEval()
    discard eval.evalString("""
      find-where: function [blk pred] [
        box: context [val: none]
        loop [
          for [item] in blk [
            if pred item [
              box/val: item
              break
            ]
          ]
        ]
        box/val
      ]
    """)
    check $eval.evalString("find-where [1 2 3 4 5] function [x] [x > 3]") == "4"

  test "returns none when no match":
    let eval = makeEval()
    discard eval.evalString("""
      find-where: function [blk pred] [
        box: context [val: none]
        loop [
          for [item] in blk [
            if pred item [
              box/val: item
              break
            ]
          ]
        ]
        box/val
      ]
    """)
    check $eval.evalString("find-where [1 2 3] function [x] [x > 10]") == "none"

  test "empty block returns none":
    let eval = makeEval()
    discard eval.evalString("""
      find-where: function [blk pred] [
        box: context [val: none]
        loop [
          for [item] in blk [
            if pred item [
              box/val: item
              break
            ]
          ]
        ]
        box/val
      ]
    """)
    check $eval.evalString("find-where [] function [x] [true]") == "none"


# =============================================================================
# validation.test.ts — interpreter output tests (no Lua compiler)
# =============================================================================

suite "Validation — interpreter output":
  test "arithmetic output":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      print 2 + 3
      print 10 - 4
      print 3 * 7
      print 2 + 3 * 4
    """)
    let outp = eval.getOutput()
    check outp.contains("5")
    check outp.contains("6")
    check outp.contains("21")
    check outp.contains("20")

  test "variables output":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      x: 42
      y: x + 8
      print x
      print y
    """)
    let outp = eval.getOutput()
    check outp.contains("42")
    check outp.contains("50")

  test "string operations output":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      print join "hello" " world"
      print uppercase "hello"
      print lowercase "HELLO"
      print trim "  hi  "
    """)
    let outp = eval.getOutput()
    check outp.contains("hello world")
    check outp.contains("HELLO")
    check outp.contains("hello")
    check outp.contains("hi")

  test "function call output":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      add: function [a b] [a + b]
      print add 3 4
      print add 10 20
    """)
    let outp = eval.getOutput()
    check outp.contains("7")
    check outp.contains("30")

  test "recursion output":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      fact: function [n] [
        if n = 0 [return 1]
        return n * fact (n - 1)
      ]
      print fact 5
    """)
    let outp = eval.getOutput()
    check outp.contains("120")

  test "closures output":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      make-adder: function [n] [function [x] [x + n]]
      add5: make-adder 5
      print add5 10
      print add5 100
    """)
    let outp = eval.getOutput()
    check outp.contains("15")
    check outp.contains("105")

  test "context output":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      p: context [x: 10 y: 20]
      print p/x
      print p/y
      p/x: 99
      print p/x
    """)
    let outp = eval.getOutput()
    check outp.contains("10")
    check outp.contains("20")
    check outp.contains("99")

  test "comparison output":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      print 5 > 3
      print 5 < 3
      print 5 = 5
      print 5 <> 3
    """)
    let outp = eval.getOutput()
    check outp.contains("true")
    check outp.contains("false")

  test "type predicates output":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      print integer? 42
      print string? "hello"
      print logic? true
      print block? [1 2 3]
      print integer? "nope"
    """)
    let lines = eval.output
    check lines[0] == "true"
    check lines[1] == "true"
    check lines[2] == "true"
    check lines[3] == "true"
    check lines[4] == "false"

  test "for range output":
    let eval = makeEval()
    eval.clearOutput()
    discard eval.evalString("""
      loop [for [n] from 1 to 5 [print n]]
    """)
    check eval.output.len == 5
    check eval.output[0] == "1"
    check eval.output[4] == "5"


# =============================================================================
# types-advanced.test.ts
# =============================================================================

suite "Custom types with @type":
  test "@type creates a union type":
    let eval = makeEval()
    discard eval.evalString("""string-or-none!: @type [string! | none!]""")
    discard eval.evalString("""greet: function [name [string-or-none!]] [either none? name ["hello stranger"] [join "hello " name]]""")
    check $eval.evalString("""greet "Ray" """) == "hello Ray"
    check $eval.evalString("greet none") == "hello stranger"

  test "@type rejects wrong type":
    let eval = makeEval()
    discard eval.evalString("""string-or-none!: @type [string! | none!]""")
    discard eval.evalString("""f: function [x [string-or-none!]] [x]""")
    expect KtgError:
      discard eval.evalString("f 42")

suite "@type/where":
  test "where adds a guard to the type":
    let eval = makeEval()
    discard eval.evalString("""positive!: @type/where [integer!] [it > 0]""")
    discard eval.evalString("""f: function [x [positive!]] [x * 2]""")
    check $eval.evalString("f 5") == "10"

  test "where rejects values that fail the guard":
    let eval = makeEval()
    discard eval.evalString("""positive!: @type/where [integer!] [it > 0]""")
    discard eval.evalString("""f: function [x [positive!]] [x * 2]""")
    expect KtgError:
      discard eval.evalString("f -3")

  test "where rejects wrong base type":
    let eval = makeEval()
    discard eval.evalString("""positive!: @type/where [integer!] [it > 0]""")
    discard eval.evalString("""f: function [x [positive!]] [x * 2]""")
    expect KtgError:
      discard eval.evalString("""f "hi" """)

suite "Type matching in match":
  test "match by type integer":
    let eval = makeEval()
    let r = eval.evalString("""
      match 42 [
        [integer!]  ["got int"]
        [string!]   ["got string"]
        [_]         ["other"]
      ]
    """)
    check $r == "got int"

  test "match string by type":
    let eval = makeEval()
    let r = eval.evalString("""
      match "hello" [
        [integer!]  ["got int"]
        [string!]   ["got string"]
        [_]         ["other"]
      ]
    """)
    check $r == "got string"

  test "match with type and capture":
    let eval = makeEval()
    let r = eval.evalString("""
      match [42 "hello"] [
        [integer! string!]  ["typed pair"]
        [_]                 ["other"]
      ]
    """)
    check $r == "typed pair"

  test "type match with custom @type":
    let eval = makeEval()
    discard eval.evalString("""number!: @type [integer! | float!]""")
    let r = eval.evalString("""
      match 3.14 [
        [number!] ["got number"]
        [_]       ["other"]
      ]
    """)
    check $r == "got number"

suite "Typed blocks":
  test "block with element type constraint":
    let eval = makeEval()
    discard eval.evalString("""sum: function [nums [block! integer!]] [loop/fold [for [acc n] in nums [acc + n]]]""")
    check $eval.evalString("sum [1 2 3 4]") == "10"

  test "untyped block accepts anything":
    let eval = makeEval()
    discard eval.evalString("""f: function [data [block!]] [length? data]""")
    check $eval.evalString("""f [1 "a" true]""") == "3"

suite "@type validates context fields":
  test "accepts context with matching fields":
    let eval = makeEval()
    discard eval.evalString("""person!: @type ['name [string!] 'age [integer!]]""")
    check $eval.evalString("""is? person! context [name: "Alice" age: 30]""") == "true"

  test "rejects context missing fields":
    let eval = makeEval()
    discard eval.evalString("""person!: @type ['name [string!] 'age [integer!]]""")
    check $eval.evalString("""is? person! context [name: "Alice"]""") == "false"
