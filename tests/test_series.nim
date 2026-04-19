import std/[unittest, os]
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerObjectDialect()
  eval.registerAttempt()
  eval

suite "String as series — pick":
  test "pick character by index":
    let eval = makeEval()
    check $eval.evalString("""pick "hello" 1""") == "h"
    check $eval.evalString("""pick "hello" 3""") == "l"
    check $eval.evalString("""pick "hello" 5""") == "o"

  test "pick out of range":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""pick "hi" 5""")

suite "String as series — first/second/last":
  test "first of string":
    let eval = makeEval()
    check $eval.evalString("""first "hello" """) == "h"

  test "second of string":
    let eval = makeEval()
    check $eval.evalString("""second "hello" """) == "e"

  test "last of string":
    let eval = makeEval()
    check $eval.evalString("""last "hello" """) == "o"

  test "first of empty string":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""first "" """)

suite "subset":
  test "basic subset":
    let eval = makeEval()
    check $eval.evalString("""subset "hello world" 1 5""") == "hello"

  test "subset from middle":
    let eval = makeEval()
    check $eval.evalString("""subset "hello world" 7 5""") == "world"

  test "subset past end truncates":
    let eval = makeEval()
    check $eval.evalString("""subset "hi" 1 100""") == "hi"

  test "subset single char":
    let eval = makeEval()
    check $eval.evalString("""subset "abc" 2 1""") == "b"

  test "subset on block":
    let eval = makeEval()
    check $eval.evalString("subset [1 2 3 4 5] 2 3") == "[2 3 4]"

  test "subset block from start":
    let eval = makeEval()
    check $eval.evalString("subset [10 20 30 40] 1 2") == "[10 20]"

  test "subset block past end truncates":
    let eval = makeEval()
    check $eval.evalString("subset [1 2 3] 2 100") == "[2 3]"

suite "insert/remove on strings":
  test "insert string at position":
    let eval = makeEval()
    check $eval.evalString("""insert "helo" "l" 4""") == "hello"

  test "insert at start":
    let eval = makeEval()
    check $eval.evalString("""insert "world" "hello " 1""") == "hello world"

  test "insert at end":
    let eval = makeEval()
    check $eval.evalString("""insert "hell" "o" 5""") == "hello"

  test "remove char from string":
    let eval = makeEval()
    check $eval.evalString("""remove "hello" 2""") == "hllo"

  test "remove first char":
    let eval = makeEval()
    check $eval.evalString("""remove "hello" 1""") == "ello"

  test "remove last char":
    let eval = makeEval()
    check $eval.evalString("""remove "hello" 5""") == "hell"

suite "read / write":
  let testFile = getTempDir() / "kintsugi_test_rw.txt"

  test "write and read file":
    let eval = makeEval()
    discard eval.evalString("write \"" & testFile & "\" \"hello from kintsugi\"")
    check $eval.evalString("read \"" & testFile & "\"") == "hello from kintsugi"

  test "read with string path":
    let eval = makeEval()
    writeFile(testFile, "test content")
    check $eval.evalString("read \"" & testFile & "\"") == "test content"

  test "read not found":
    let eval = makeEval()
    expect KtgError:
      discard eval.evalString("""read "/nonexistent/path.txt" """)

  teardown:
    if fileExists(testFile):
      removeFile(testFile)

