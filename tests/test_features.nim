import std/[unittest, os, sets, tables]
import ../src/core/types
import ../src/eval/[dialect, evaluator, natives]
import ../src/dialects/[loop_dialect, object_dialect]

proc makeEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerObjectDialect()
  eval

suite "make map!":
  test "create map from block":
    let eval = makeEval()
    discard eval.evalString("""m: make map! [name: "Ray" age: 30]""")
    check $eval.evalString("m/name") == "Ray"
    check $eval.evalString("m/age") == "30"

  test "map size":
    let eval = makeEval()
    discard eval.evalString("""m: make map! [a: 1 b: 2 c: 3]""")
    check $eval.evalString("size? m") == "3"

  test "map has? with string key":
    let eval = makeEval()
    discard eval.evalString("""m: make map! [name: "Ray"]""")
    check $eval.evalString("""has? m "name" """) == "true"
    check $eval.evalString("""has? m "missing" """) == "false"

  test "map set-path":
    let eval = makeEval()
    discard eval.evalString("""m: make map! [x: 1]""")
    discard eval.evalString("m/x: 42")
    check $eval.evalString("m/x") == "42"

suite "make set! and charset":
  test "make set! from values":
    let eval = makeEval()
    discard eval.evalString("""s: make set! ["a" "b" "c"]""")
    check $eval.evalString("""has? s "a" """) == "true"
    check $eval.evalString("""has? s "z" """) == "false"

  test "charset from string":
    let eval = makeEval()
    discard eval.evalString("""hex: charset "0123456789abcdef" """)
    check $eval.evalString("""has? hex "a" """) == "true"
    check $eval.evalString("""has? hex "g" """) == "false"
    check $eval.evalString("""has? hex "0" """) == "true"

  test "set size":
    let eval = makeEval()
    discard eval.evalString("""s: make set! ["x" "y" "z"]""")
    check $eval.evalString("size? s") == "3"

  test "has? on set with integer":
    let eval = makeEval()
    discard eval.evalString("""s: make set! [1 2 3]""")
    check $eval.evalString("""has? s 2""") == "true"
    check $eval.evalString("""has? s 9""") == "false"

suite "set operations":
  test "union of two sets":
    let eval = makeEval()
    discard eval.evalString("""a: make set! ["x" "y"]""")
    discard eval.evalString("""b: make set! ["y" "z"]""")
    discard eval.evalString("c: union a b")
    check $eval.evalString("""has? c "x" """) == "true"
    check $eval.evalString("""has? c "y" """) == "true"
    check $eval.evalString("""has? c "z" """) == "true"
    check $eval.evalString("size? c") == "3"

  test "intersect of two sets":
    let eval = makeEval()
    discard eval.evalString("""a: make set! ["x" "y" "z"]""")
    discard eval.evalString("""b: make set! ["y" "z" "w"]""")
    discard eval.evalString("c: intersect a b")
    check $eval.evalString("""has? c "y" """) == "true"
    check $eval.evalString("""has? c "z" """) == "true"
    check $eval.evalString("""has? c "x" """) == "false"
    check $eval.evalString("size? c") == "2"

suite "sort/by":
  test "sort/by with key function":
    let eval = makeEval()
    discard eval.evalString("items: [3 1 2]")
    discard eval.evalString("neg: function [x] [negate x]")
    discard eval.evalString("sort/by items :neg")
    check $eval.evalString("first items") == "3"
    check $eval.evalString("last items") == "1"

  test "plain sort still works":
    let eval = makeEval()
    discard eval.evalString("items: [3 1 2]")
    discard eval.evalString("sort items")
    check $eval.evalString("first items") == "1"
    check $eval.evalString("last items") == "3"

suite "load and import":
  test "load returns parsed block":
    let tmpFile = getTempDir() / "test_load.ktg"
    writeFile(tmpFile, """x: 42""")
    let eval = makeEval()
    discard eval.evalString("data: load \"" & tmpFile & "\"")
    check $eval.evalString("size? data") == "2"  # set-word x: and integer 42
    removeFile(tmpFile)

  test "load/eval returns frozen object":
    let tmpFile = getTempDir() / "test_load_eval.ktg"
    writeFile(tmpFile, "x: 42\ny: 10")
    let eval = makeEval()
    discard eval.evalString("mod: load/eval \"" & tmpFile & "\"")
    check $eval.evalString("mod/x") == "42"
    check $eval.evalString("mod/y") == "10"
    removeFile(tmpFile)

  test "import caches modules":
    let tmpFile = getTempDir() / "test_import.ktg"
    writeFile(tmpFile, "counter: 1")
    let eval = makeEval()
    discard eval.evalString("a: import \"" & tmpFile & "\"")
    discard eval.evalString("b: import \"" & tmpFile & "\"")
    # Both should be the same cached object
    check $eval.evalString("a/counter") == "1"
    check $eval.evalString("b/counter") == "1"
    removeFile(tmpFile)

  test "import strips Kintsugi header":
    let tmpFile = getTempDir() / "test_import_header.ktg"
    writeFile(tmpFile, "Kintsugi [title: \"test\"]\nx: 99")
    let eval = makeEval()
    discard eval.evalString("m: import \"" & tmpFile & "\"")
    check $eval.evalString("m/x") == "99"
    removeFile(tmpFile)

suite "exports":
  test "exports filters module fields":
    let tmpFile = getTempDir() / "test_exports.ktg"
    writeFile(tmpFile, "exports [add]\nadd: function [a b] [a + b]\nsecret: 42")
    let eval = makeEval()
    discard eval.evalString("m: import \"" & tmpFile & "\"")
    check $eval.evalString("type m/add 1 2") == "integer!"  # confirm add works
    check $eval.evalString("m/add 3 4") == "7"
    # secret should not be exported
    discard eval.evalString("r: try [m/secret]")
    check $eval.evalString("r/ok") == "false"
    removeFile(tmpFile)

suite "save":
  test "save and load roundtrip":
    let tmpFile = getTempDir() / "test_save.ktg"
    let eval = makeEval()
    discard eval.evalString("""save """ & "\"" & tmpFile & "\"" & """ 42""")
    let content = readFile(tmpFile)
    check content == "42"
    removeFile(tmpFile)

  test "save string with quotes":
    let tmpFile = getTempDir() / "test_save_str.ktg"
    let eval = makeEval()
    discard eval.evalString("save \"" & tmpFile & "\" \"hello world\"")
    let content = readFile(tmpFile)
    check content == "\"hello world\""
    removeFile(tmpFile)

  test "save block":
    let tmpFile = getTempDir() / "test_save_blk.ktg"
    let eval = makeEval()
    discard eval.evalString("save \"" & tmpFile & "\" [1 2 3]")
    let content = readFile(tmpFile)
    check content == "[1 2 3]"
    removeFile(tmpFile)

  test "save map":
    let tmpFile = getTempDir() / "test_save_map.ktg"
    let eval = makeEval()
    discard eval.evalString("""m: make map! [a: 1 b: 2]""")
    discard eval.evalString("save \"" & tmpFile & "\" m")
    let content = readFile(tmpFile)
    check content == "[a: 1 b: 2]"
    removeFile(tmpFile)
