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

suite "poke":
  test "poke block by integer index writes through":
    let eval = makeEval()
    discard eval.evalString("obj: [1 2 3]")
    discard eval.evalString("poke obj 2 99")
    check $eval.evalString("obj") == "[1 99 3]"

  test "poke block returns the written value":
    let eval = makeEval()
    discard eval.evalString("obj: [1 2 3]")
    check $eval.evalString("poke obj 1 42") == "42"

  test "poke block out-of-range errors":
    let eval = makeEval()
    discard eval.evalString("obj: [1 2 3]")
    expect KtgError:
      discard eval.evalString("poke obj 5 99")

  test "poke block with non-integer key errors":
    let eval = makeEval()
    discard eval.evalString("obj: [1 2 3]")
    expect KtgError:
      discard eval.evalString("""poke obj "foo" 99""")

  test "poke string by integer index writes a char":
    let eval = makeEval()
    discard eval.evalString("""s: "hello" """)
    discard eval.evalString("""poke s 1 "H" """)
    check $eval.evalString("s") == "Hello"

  test "poke map by key writes through":
    let eval = makeEval()
    discard eval.evalString("""m: make map! [a: 1 b: 2]""")
    discard eval.evalString("""poke m 'a 99""")
    check $eval.evalString("""m/a""") == "99"

  test "poke map creates missing key":
    let eval = makeEval()
    discard eval.evalString("""m: make map! [a: 1]""")
    discard eval.evalString("""poke m 'b 2""")
    check $eval.evalString("""m/b""") == "2"

  test "poke context by word key writes through":
    let eval = makeEval()
    discard eval.evalString("""c: context [x: 1 y: 2]""")
    discard eval.evalString("""poke c 'x 99""")
    check $eval.evalString("""c/x""") == "99"

  test "poke variable name drives the index":
    let eval = makeEval()
    discard eval.evalString("obj: [1 2 3]")
    discard eval.evalString("i: 2")
    discard eval.evalString("poke obj i 99")
    check $eval.evalString("obj") == "[1 99 3]"

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

