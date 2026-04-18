import std/unittest
import std/strutils
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/loop_dialect
import ../src/parse/parser
import ../src/emit/lua
import ./emit_test_helper

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval

suite "import: interpreter":
  test "import lit-word makes module namespaced":
    let eval = makeEval()
    discard eval.evalString("import 'math")
    discard eval.evalString("print math/clamp 15 0 10")
    check eval.output == @["10"]

  test "import block of lit-words loads multiple modules":
    let eval = makeEval()
    discard eval.evalString("import ['math 'collections]")
    discard eval.evalString("print math/clamp 15 0 10")
    check eval.output == @["10"]

  test "import/using flattens selected names into bare scope":
    let eval = makeEval()
    discard eval.evalString("import/using 'math [clamp]")
    discard eval.evalString("print clamp 15 0 10")
    check eval.output == @["10"]

  test "import/using selective - unlisted names raise error":
    let eval = makeEval()
    discard eval.evalString("import/using 'math [clamp]")
    expect KtgError:
      discard eval.evalString("lerp 0.0 1.0 0.5")

  test "unimported stdlib is inaccessible":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("clamp 15 0 10")

  test "std/math backdoor is closed":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("std/math")

  test "unknown module raises error":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("import 'nonexistent")

suite "import: compiler":
  test "import + namespaced call emits lua with clamp":
    let eval = makeEval()
    let ast = parseSource("import 'math\nprint math/clamp 15 0 10")
    let processed = eval.preprocess(ast, forCompilation = true)
    let code = emitLua(processed)
    check "clamp" in code

  test "import/using emits flattened function":
    let eval = makeEval()
    let ast = parseSource("import/using 'math [clamp]\nprint clamp 15 0 10")
    let processed = eval.preprocess(ast, forCompilation = true)
    let code = emitLua(processed)
    check "clamp" in code
