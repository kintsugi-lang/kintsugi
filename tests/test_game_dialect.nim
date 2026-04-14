import std/unittest, std/tables
import ../src/core/types
import ../src/dialects/game_dialect
import ../src/parse/parser
import ../src/eval/[evaluator, natives]

suite "game dialect skeleton":
  test "love2d backend is registered":
    check backends.hasKey("love2d")
    check backends["love2d"].name == "love2d"

  test "unknown target raises compile error":
    let blk = @[
      ktgWord("target", wkSetWord),
      ktgWord("playstation6", wkLitWord),
    ]
    expect(ValueError):
      discard expand(blk)

proc setupEvaluator(): Evaluator =
  result = newEvaluator()
  result.registerNatives()

suite "game dialect preprocess wiring":
  test "bare @game splices empty expansion":
    let src = "Kintsugi [name: 'test]\n@game [target: 'love2d]\nprint \"hi\"\n"
    let ast = parseSource(src)
    let eval = setupEvaluator()
    let processed = eval.preprocess(ast, forCompilation = true)
    ## Both the @game metaword AND its block argument should be consumed.
    ## The only remaining top-level forms are the Kintsugi header block
    ## and `print "hi"`.
    for v in processed:
      check not (v.kind == vkWord and v.wordKind == wkMetaWord and v.wordName == "game")
      ## No leaked `target:` set-word from inside the @game block either.
      check not (v.kind == vkWord and v.wordKind == wkSetWord and v.wordName == "target")
    ## The `print` word must still be present - confirms the splice happened
    ## at the right position and subsequent forms survived.
    var sawPrint = false
    for v in processed:
      if v.kind == vkWord and v.wordKind == wkWord and v.wordName == "print":
        sawPrint = true
    check sawPrint
