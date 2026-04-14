import std/[unittest, tables, os, strutils]
import ../src/core/types
import ../src/core/pretty
import ../src/dialects/game_dialect
import ../src/parse/parser
import ../src/eval/[evaluator, natives]
import ../src/emit/lua

suite "game dialect skeleton":
  test "love2d backend is registered":
    check backends.hasKey("love2d")
    check backends["love2d"].name == "love2d"

  test "playdate backend is registered":
    check backends.hasKey("playdate")
    check backends["playdate"].name == "playdate"

  test "unknown target raises compile error":
    expect(ValueError):
      discard expand(@[], "playstation6")

  test "missing target raises compile error":
    expect(ValueError):
      discard expand(@[], "")

proc setupEvaluator(): Evaluator =
  result = newEvaluator()
  result.registerNatives()

suite "game dialect expansion":
  test "constants inline at references, no @const emitted":
    let blk = @[
      ktgWord("constants", wkWord),
      ktgBlock(@[
        ktgWord("SCREEN-W", wkSetWord), ktgInt(800),
        ktgWord("SCREEN-H", wkSetWord), ktgInt(600),
      ]),
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgWord("SCREEN-W", wkWord), ktgWord("SCREEN-H", wkWord),
          ktgWord("rect", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    for v in output:
      check not (v.kind == vkWord and v.wordKind == wkMetaWord and v.wordName == "const")
    var foundPlayer = false
    for i in 0 ..< output.len - 2:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "player" and output[i + 2].kind == vkBlock:
        let ctx = output[i + 2].blockVals
        check ctx[0].wordName == "x" and ctx[1].kind == vkInteger and ctx[1].intVal == 800
        check ctx[2].wordName == "y" and ctx[3].kind == vkInteger and ctx[3].intVal == 600
        foundPlayer = true
    check foundPlayer

  test "entity expands to set-word context on love2d (color stored)":
    let blk = @[
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
    let output = expand(blk, "love2d")
    var found = false
    for i in 0 ..< output.len - 2:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "player":
        check output[i + 1].kind == vkWord and output[i + 1].wordName == "context"
        let ctx = output[i + 2].blockVals
        check ctx.len == 14  # 7 set-words + 7 values (x y w h cr cg cb)
        check ctx[0].wordName == "x" and ctx[1].intVal == 20
        check ctx[8].wordName == "cr"
        found = true
    check found

  test "entity on playdate drops color fields (monochrome)":
    let blk = @[
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
    let output = expand(blk, "playdate")
    var found = false
    for i in 0 ..< output.len - 2:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "player":
        let ctx = output[i + 2].blockVals
        check ctx.len == 8  # x y w h only
        for v in ctx:
          check not (v.kind == vkWord and v.wordKind == wkSetWord and
                     v.wordName in ["cr", "cg", "cb"])
        found = true
    check found

  test "pos and rect accept a pair literal":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgPair(20, 260),
          ktgWord("rect", wkWord), ktgPair(12, 80),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var found = false
    for i in 0 ..< output.len - 2:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "player" and output[i + 2].kind == vkBlock:
        let ctx = output[i + 2].blockVals
        check ctx[0].wordName == "x" and ctx[1].intVal == 20
        check ctx[2].wordName == "y" and ctx[3].intVal == 260
        check ctx[4].wordName == "w" and ctx[5].intVal == 12
        check ctx[6].wordName == "h" and ctx[7].intVal == 80
        found = true
    check found

  test "love/draw emits setColor + rectangle per entity directly":
    let blk = @[
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
    let output = expand(blk, "love2d")
    var drawBody: seq[KtgValue] = @[]
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/draw" and output[i + 3].kind == vkBlock:
        drawBody = output[i + 3].blockVals
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

  test "playdate draw body emits fillRect directly, no setColor":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(20), ktgInt(260),
          ktgWord("rect", wkWord), ktgInt(12), ktgInt(80),
        ]),
      ]),
    ]
    let output = expand(blk, "playdate")
    var sawFillRect = false
    proc scan(vs: seq[KtgValue]) =
      for v in vs:
        if v.kind == vkWord and v.wordName == "playdate/graphics/fillRect":
          sawFillRect = true
        elif v.kind == vkBlock: scan(v.blockVals)
        elif v.kind == vkParen: scan(v.parenVals)
    scan(output)
    check sawFillRect
    ## No color primitives of any kind on monochrome.
    for v in output:
      check not (v.kind == vkWord and v.wordName == "set-color")

  test "custom entity draw block replaces auto-rect":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(20), ktgInt(260),
          ktgWord("rect", wkWord), ktgInt(12), ktgInt(80),
          ktgWord("color", wkWord), ktgFloat(0.9), ktgFloat(0.9), ktgFloat(1.0),
          ktgWord("draw", wkWord),
          ktgBlock(@[
            ktgWord("love/graphics/print", wkWord),
            ktgString("hi"),
            ktgWord("self/x", wkWord),
            ktgWord("self/y", wkWord),
          ]),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var drawBody: seq[KtgValue] = @[]
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/draw" and output[i + 3].kind == vkBlock:
        drawBody = output[i + 3].blockVals
    ## No auto-rect: no setColor/rectangle call for this entity.
    for v in drawBody:
      check not (v.kind == vkWord and v.wordName == "love/graphics/setColor")
      check not (v.kind == vkWord and v.wordName == "love/graphics/rectangle")
    ## self/x and self/y are substituted to player/x and player/y.
    var sawPrint, sawPlayerX, sawPlayerY = false
    for v in drawBody:
      if v.kind == vkWord:
        case v.wordName
        of "love/graphics/print": sawPrint = true
        of "player/x": sawPlayerX = true
        of "player/y": sawPlayerY = true
        else: discard
    check sawPrint
    check sawPlayerX
    check sawPlayerY

  test "field inside entity adds to context":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
          ktgWord("field", wkWord), ktgWord("score", wkWord), ktgInt(0),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var found = false
    for i in 0 ..< output.len - 2:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "player" and output[i + 2].kind == vkBlock:
        let ctx = output[i + 2].blockVals
        var sawScore = false
        for j in 0 ..< ctx.len - 1:
          if ctx[j].kind == vkWord and ctx[j].wordKind == wkSetWord and
             ctx[j].wordName == "score":
            check ctx[j + 1].kind == vkInteger and ctx[j + 1].intVal == 0
            sawScore = true
        check sawScore
        found = true
    check found

  test "update body self substitution":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
          ktgWord("update", wkWord),
          ktgBlock(@[
            ktgWord("self/y", wkSetWord),
            ktgWord("self/y", wkWord),
            ktgInt(5),
          ]),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var found = false
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/update" and output[i + 3].kind == vkBlock:
        let body = output[i + 3].blockVals
        check body.len == 3
        check body[0].wordName == "player/y"
        check body[1].wordName == "player/y"
        check body[2].intVal == 5
        found = true
    check found

  test "state lifts to top-level set-words":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("state", wkWord),
        ktgBlock(@[
          ktgWord("paused?", wkSetWord), ktgLogic(true),
          ktgWord("score", wkSetWord), ktgInt(0),
        ]),
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var pausedIdx, scoreIdx, playerIdx = -1
    for i in 0 ..< output.len:
      let v = output[i]
      if v.kind == vkWord and v.wordKind == wkSetWord:
        if v.wordName == "paused?": pausedIdx = i
        if v.wordName == "score": scoreIdx = i
        if v.wordName == "player": playerIdx = i
    check pausedIdx >= 0
    check scoreIdx >= 0
    check pausedIdx < playerIdx
    check scoreIdx < playerIdx

  test "user-supplied bindings merge with backend bindings":
    let blk = @[
      ktgWord("bindings", wkWord),
      ktgBlock(@[
        ktgWord("my/custom/call", wkWord),
        ktgString("my.custom.call"),
        ktgWord("call", wkLitWord),
        ktgInt(2),
      ]),
    ]
    let output = expand(blk, "love2d")
    check output[0].kind == vkWord and output[0].wordName == "bindings"
    check output[1].kind == vkBlock
    var sawCustom = false
    for entry in output[1].blockVals:
      if entry.kind == vkWord and entry.wordName == "my/custom/call":
        sawCustom = true
    check sawCustom

  test "tags are collected per entity":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("tags", wkWord), ktgBlock(@[ktgWord("paddle", wkWord)]),
        ]),
        ktgWord("entity", wkWord), ktgWord("cpu", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("tags", wkWord), ktgBlock(@[ktgWord("paddle", wkWord)]),
        ]),
        ktgWord("entity", wkWord), ktgWord("ball", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(5), ktgInt(5),
          ktgWord("tags", wkWord), ktgBlock(@[ktgWord("ball", wkWord)]),
        ]),
      ]),
    ]
    let tagMap = collectTagMap(blk)
    check tagMap.hasKey("paddle")
    check tagMap["paddle"].len == 2
    check "player" in tagMap["paddle"]
    check "cpu" in tagMap["paddle"]
    check tagMap.hasKey("ball")
    check "ball" in tagMap["ball"]

  test "collide enumerates per-tag with flat if all? blocks":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("tags", wkWord), ktgBlock(@[ktgWord("paddle", wkWord)]),
        ]),
        ktgWord("entity", wkWord), ktgWord("cpu", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("tags", wkWord), ktgBlock(@[ktgWord("paddle", wkWord)]),
        ]),
        ktgWord("entity", wkWord), ktgWord("ball", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(5), ktgInt(5),
        ]),
        ktgWord("collide", wkWord), ktgWord("ball", wkWord), ktgWord("paddle", wkLitWord),
        ktgBlock(@[ktgWord("ball/dx", wkSetWord), ktgInt(1)]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var allCount = 0
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/update" and output[i + 3].kind == vkBlock:
        let body = output[i + 3].blockVals
        for v in body:
          if v.kind == vkWord and v.wordName == "all?":
            allCount += 1
    check allCount == 2

  test "scene-level draw body appears in love/draw":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
        ]),
        ktgWord("draw", wkWord),
        ktgBlock(@[
          ktgWord("love/graphics/print", wkWord),
          ktgString("hello"),
          ktgInt(10),
          ktgInt(20),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var foundPrint = false
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/draw" and output[i + 3].kind == vkBlock:
        for v in output[i + 3].blockVals:
          if v.kind == vkWord and v.wordName == "love/graphics/print":
            foundPrint = true
    check foundPrint

  test "self in scene draw block raises":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("draw", wkWord),
        ktgBlock(@[ktgWord("self/x", wkWord)]),
      ]),
    ]
    expect(ValueError):
      discard expand(blk, "love2d")

  test "scene-level on-update body appears first in love/update":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("on-update", wkWord),
        ktgBlock(@[
          ktgWord("if", wkWord),
          ktgWord("paused?", wkWord),
          ktgBlock(@[ktgWord("return", wkWord)]),
        ]),
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
          ktgWord("update", wkWord),
          ktgBlock(@[ktgWord("self/y", wkSetWord), ktgInt(1)]),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var found = false
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/update" and output[i + 3].kind == vkBlock:
        let body = output[i + 3].blockVals
        check body.len >= 3
        check body[0].wordName == "if"
        check body[1].wordName == "paused?"
        found = true
    check found

  test "self in scene on-update block raises":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("on-update", wkWord),
        ktgBlock(@[ktgWord("self/x", wkWord)]),
      ]),
    ]
    expect(ValueError):
      discard expand(blk, "love2d")

suite "game dialect preprocess wiring":
  test "bare @game splices empty expansion":
    let src = "Kintsugi [name: 'test]\n@game [scene 'main []]\nprint \"hi\"\n"
    let ast = parseSource(src)
    let eval = setupEvaluator()
    let processed = eval.preprocess(ast, forCompilation = true, target = "love2d")
    for v in processed:
      check not (v.kind == vkWord and v.wordKind == wkMetaWord and v.wordName == "game")
    var sawPrint = false
    for v in processed:
      if v.kind == vkWord and v.wordKind == wkWord and v.wordName == "print":
        sawPrint = true
    check sawPrint

  test "@game without target raises in preprocess":
    let src = "Kintsugi [name: 'test]\n@game [scene 'main []]\n"
    let ast = parseSource(src)
    let eval = setupEvaluator()
    expect(ValueError):
      discard eval.preprocess(ast, forCompilation = true)

suite "game dialect backend prelude":
  test "playdate emits CoreLibs imports at top-of-file":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("p", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(1), ktgInt(1),
        ]),
      ]),
    ]
    let output = expand(blk, "playdate")
    var rawPayload = ""
    var i = 0
    while i + 1 < output.len:
      if output[i].kind == vkWord and output[i].wordName == "raw" and
         output[i + 1].kind == vkString:
        rawPayload &= output[i + 1].strVal & "\n"
      i += 1
    check "import \"CoreLibs/graphics\"" in rawPayload
    check "import \"CoreLibs/sprites\"" in rawPayload
    check "import \"CoreLibs/timer\"" in rawPayload

  test "playdate framePrelude injects dt and clear into update body":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("p", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(1), ktgInt(1),
        ]),
      ]),
    ]
    let output = expand(blk, "playdate")
    var sawDtClear = false
    var i = 0
    while i + 3 < output.len:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "playdate/update" and
         output[i + 3].kind == vkBlock:
        let body = output[i + 3].blockVals
        if body.len >= 2 and body[0].wordName == "raw" and body[1].kind == vkString:
          let s = body[1].strVal
          check "local dt = 1/30" in s
          check "playdate.graphics.clear()" in s
          sawDtClear = true
      i += 1
    check sawDtClear

  test "love2d framePrelude is empty":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("p", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(1), ktgInt(1),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var updateBody: seq[KtgValue]
    var i = 0
    while i + 3 < output.len:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/update" and output[i + 3].kind == vkBlock:
        updateBody = output[i + 3].blockVals
      i += 1
    for v in updateBody:
      check not (v.kind == vkWord and v.wordName == "raw")

  test "love2d prelude is empty":
    let output = expand(@[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[]),
    ], "love2d")
    for v in output:
      check not (v.kind == vkWord and v.wordName == "raw")

# ---------------------------------------------------------------------------
# Three-layer golden runner for @game dialect files
#
# Update goldens: KINTSUGI_UPDATE_GOLDENS=1 nim c -r tests/test_game_dialect.nim
# ---------------------------------------------------------------------------

proc gameSetupEval(): Evaluator =
  result = newEvaluator()
  result.registerNatives()

proc dryExpand(src, target: string): string =
  let source = applyUsingHeader(src)
  let ast = parseSource(source)
  let eval = gameSetupEval()
  let expanded = eval.preprocess(ast, forCompilation = true, target = target)
  prettyPrintBlock(expanded)

proc compileGameKtg(src, sourceDir, target: string): string =
  let source = applyUsingHeader(src)
  let ast = parseSource(source)
  let eval = gameSetupEval()
  let processed = eval.preprocess(ast, forCompilation = true, target = target)
  emitLua(processed, sourceDir)

proc normLF(s: string): string =
  s.replace("\r\n", "\n").replace("\r", "\n")

let gameGoldenDir = currentSourcePath().parentDir / "golden"
let updateGameGoldens = getEnv("KINTSUGI_UPDATE_GOLDENS") == "1"

suite "game dialect goldens (three layer)":
  for (name, target) in @[
    ("game_pong_stub",      "love2d"),
    ("game_pong_nocollide", "love2d"),
    ("game_pong",           "love2d"),
    ("game_pong_playdate",  "playdate"),
  ]:
    test name:
      let ktgPath = gameGoldenDir / (name & ".ktg")
      let expPath = gameGoldenDir / (name & "_expanded.ktg")
      let luaPath = gameGoldenDir / (name & ".lua")

      let src = readFile(ktgPath)
      let actualExpanded = normLF(dryExpand(src, target)) & "\n"
      let actualLua = normLF(compileGameKtg(src, gameGoldenDir, target))

      if updateGameGoldens:
        writeFile(expPath, actualExpanded)
        writeFile(luaPath, actualLua)
        echo "  [updated] ", name, "_expanded.ktg"
        echo "  [updated] ", name, ".lua"
        check true
      else:
        check fileExists(expPath)
        check fileExists(luaPath)
        check normLF(readFile(expPath)) == actualExpanded
        check normLF(readFile(luaPath)) == actualLua
