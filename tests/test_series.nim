import std/[unittest, os]
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

suite "Parse dialect for lexer-like tokenization":
  test "tokenize simple arithmetic":
    let eval = makeEval()
    discard eval.evalString("""
      r: @parse "123 + 456" [
        a: some digit
        some space
        op: "+"
        some space
        b: some digit
      ]
    """)
    check $eval.evalString("r/ok") == "true"
    check $eval.evalString("r/a") == "123"
    check $eval.evalString("r/b") == "456"

  test "tokenize word-like identifiers":
    let eval = makeEval()
    let ident = makeEval()
    discard ident.evalString("""
      r: @parse "hello-world" [
        name: some [alpha | "-"]
      ]
    """)
    check $ident.evalString("r/ok") == "true"
    check $ident.evalString("r/name") == "hello-world"

  test "collect multiple tokens":
    let eval = makeEval()
    discard eval.evalString("""
      r: @parse "abc,def,ghi" [
        words: collect [
          keep some alpha
          some ["," keep some alpha]
        ]
      ]
    """)
    check $eval.evalString("r/ok") == "true"
    check $eval.evalString("r/words") == "[abc def ghi]"

  test "scan to delimiter":
    let eval = makeEval()
    discard eval.evalString("""
      r: @parse "key=value" [
        k: to "="
        "="
        v: some [alpha | digit]
      ]
    """)
    check $eval.evalString("r/ok") == "true"
    check $eval.evalString("r/k") == "key"
    check $eval.evalString("r/v") == "value"

  test "alternatives for different token types":
    let eval = makeEval()
    discard eval.evalString("""
      r: @parse "42" [
        tokens: collect [
          some [
            keep some digit
            | keep some alpha
            | skip
          ]
        ]
      ]
    """)
    check $eval.evalString("r/ok") == "true"
    check $eval.evalString("first r/tokens") == "42"

  test "nested block parsing for AST":
    let eval = makeEval()
    discard eval.evalString("""
      r: @parse [add 1 2] [
        op: word!
        a: integer!
        b: integer!
      ]
    """)
    check $eval.evalString("r/ok") == "true"
    check $eval.evalString("r/a") == "1"
    check $eval.evalString("r/b") == "2"
