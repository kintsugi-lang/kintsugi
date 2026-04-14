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

suite "game dialect expansion":
  test "constants become @const entries":
    let blk = @[
      ktgWord("target", wkSetWord), ktgWord("love2d", wkLitWord),
      ktgWord("constants", wkWord),
      ktgBlock(@[
        ktgWord("SCREEN-W", wkSetWord), ktgInt(800),
        ktgWord("SCREEN-H", wkSetWord), ktgInt(600),
      ]),
    ]
    let output = expand(blk)
    check output.len == 6
    check output[0].kind == vkWord and output[0].wordKind == wkMetaWord and output[0].wordName == "const"
    check output[1].kind == vkWord and output[1].wordKind == wkSetWord and output[1].wordName == "SCREEN-W"
    check output[2].kind == vkInteger and output[2].intVal == 800
    check output[3].kind == vkWord and output[3].wordKind == wkMetaWord and output[3].wordName == "const"
    check output[4].kind == vkWord and output[4].wordKind == wkSetWord and output[4].wordName == "SCREEN-H"
    check output[5].kind == vkInteger and output[5].intVal == 600

  test "entity expands to set-word context":
    let blk = @[
      ktgWord("target", wkSetWord), ktgWord("love2d", wkLitWord),
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(20), ktgInt(260),
          ktgWord("rect", wkWord), ktgInt(12), ktgInt(80),
          ktgWord("color", wkWord), ktgFloat(0.9), ktgFloat(0.9), ktgFloat(1.0),
        ]),
      ]),
    ]
    let output = expand(blk)
    var found = false
    for i in 0 ..< output.len - 2:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "player":
        check output[i + 1].kind == vkWord and output[i + 1].wordKind == wkWord
        check output[i + 1].wordName == "context"
        check output[i + 2].kind == vkBlock
        let ctx = output[i + 2].blockVals
        check ctx.len == 14  # 7 set-words + 7 values
        check ctx[0].kind == vkWord and ctx[0].wordKind == wkSetWord and ctx[0].wordName == "x"
        check ctx[1].kind == vkInteger and ctx[1].intVal == 20
        check ctx[2].wordName == "y" and ctx[3].intVal == 260
        check ctx[4].wordName == "w" and ctx[5].intVal == 12
        check ctx[6].wordName == "h" and ctx[7].intVal == 80
        check ctx[8].wordName == "cr"
        check ctx[10].wordName == "cg"
        check ctx[12].wordName == "cb"
        found = true
    check found

  test "love/draw emits setColor + drawRect per entity":
    let blk = @[
      ktgWord("target", wkSetWord), ktgWord("love2d", wkLitWord),
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(20), ktgInt(260),
          ktgWord("rect", wkWord), ktgInt(12), ktgInt(80),
          ktgWord("color", wkWord), ktgFloat(0.9), ktgFloat(0.9), ktgFloat(1.0),
        ]),
      ]),
    ]
    let output = expand(blk)
    var sawLoad, sawUpdate, sawDraw, sawKeypressed = false
    for v in output:
      if v.kind == vkWord and v.wordKind == wkSetWord:
        case v.wordName
        of "love/load": sawLoad = true
        of "love/update": sawUpdate = true
        of "love/draw": sawDraw = true
        of "love/keypressed": sawKeypressed = true
        else: discard
    check sawLoad
    check sawUpdate
    check sawDraw
    check sawKeypressed
    ## Locate love/draw body block (3 tokens after the set-word).
    var drawBody: seq[KtgValue] = @[]
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/draw" and output[i + 3].kind == vkBlock:
        drawBody = output[i + 3].blockVals
    ## Draw body should contain setColor and rectangle calls referencing player's fields.
    var sawSetColor, sawRect, sawPlayerCr, sawPlayerX = false
    for v in drawBody:
      if v.kind == vkWord and v.wordKind == wkWord:
        case v.wordName
        of "love/graphics/setColor": sawSetColor = true
        of "love/graphics/rectangle": sawRect = true
        of "player/cr": sawPlayerCr = true
        of "player/x": sawPlayerX = true
        else: discard
    check sawSetColor
    check sawRect
    check sawPlayerCr
    check sawPlayerX

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
