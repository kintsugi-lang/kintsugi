## Error formatting: line propagation, path context, source preview + caret.

import std/[unittest, strutils]
import ../src/core/[types, errors]
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

proc catch(src: string): KtgError =
  let eval = makeEval()
  try:
    discard eval.evalString(src)
  except KtgError as e:
    return e
  fail()
  nil

suite "error line propagation":
  test "undefined word carries line 1":
    let e = catch("undefined-word")
    check e.line == 1

  test "error on later line carries that line":
    let e = catch("x: 1\ny: 2\nundefined-word")
    check e.line == 3

  test "type error in middle of block carries its line":
    let e = catch("a: 1\nb: 2\na + \"x\"\nc: 3")
    check e.line == 3

  test "path navigation on wrong type carries line":
    let e = catch("x: 10\ny: 20\nx/pos/z")
    check e.line == 3

  test "missing field on map carries line":
    let e = catch("m: make map! []\nm/missing")
    check e.line == 2

suite "path error context":
  test "path error records path word":
    let e = catch("x: 10\nx/pos/z")
    check e.path == "x/pos/z"
    check e.pathSeg == "pos"

  test "set-path error records path word":
    let e = catch("x: 10\nx/pos/z: 5")
    check e.path == "x/pos/z"
    check e.pathSeg == "pos"

  test "undefined field carries path context":
    let e = catch("point: context [a: 1]\npoint/missing")
    check e.path == "point/missing"
    check e.pathSeg == "missing"

suite "formatError":
  test "plain undefined word":
    let src = "undefined-word"
    let e = catch(src)
    let s = formatError(src, e)
    check s.contains("Error [undefined]:")
    check s.contains("at line 1:")
    check s.contains("| undefined-word")

  test "multi-line source shows the right line":
    let src = "x: 1\ny: 2\nz: undefined-var"
    let e = catch(src)
    let s = formatError(src, e)
    check s.contains("at line 3:")
    check s.contains("| z: undefined-var")
    check not s.contains("| x: 1")

  test "path error includes path and caret":
    let src = "x: 10\nx/pos/z: 5"
    let e = catch(src)
    let s = formatError(src, e)
    check s.contains("in path: x/pos/z")
    check s.contains("(at /pos)")
    check s.contains("at line 2:")
    check s.contains("| x/pos/z: 5")
    # caret line has the ^ char after the indent
    let lines = s.split('\n')
    var hasCaret = false
    for ln in lines:
      if ln.contains("^"):
        hasCaret = true
    check hasCaret

  test "missing line number does not crash":
    let e = KtgError(kind: "type", msg: "bogus", line: 0)
    let s = formatError("", e)
    check s == "Error [type]: bogus"

  test "line number without matching source still prints header":
    let e = KtgError(kind: "type", msg: "bogus", line: 5)
    let s = formatError("", e)
    check s.contains("Error [type]: bogus")
    check s.contains("at line 5:")

suite "sourceLine":
  test "first line":
    check sourceLine("alpha\nbeta\ngamma", 1) == "alpha"
  test "middle":
    check sourceLine("alpha\nbeta\ngamma", 2) == "beta"
  test "last line without trailing newline":
    check sourceLine("alpha\nbeta\ngamma", 3) == "gamma"
  test "last line with trailing newline":
    check sourceLine("alpha\nbeta\n", 2) == "beta"
  test "out of range returns empty":
    check sourceLine("alpha", 5) == ""
  test "line zero returns empty":
    check sourceLine("alpha", 0) == ""
