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
  test "constants inline at references, no @const emitted":
    let blk = @[
      ktgWord("target", wkSetWord), ktgWord("love2d", wkLitWord),
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
    let output = expand(blk)
    # No @const metaword anywhere in the output.
    for v in output:
      check not (v.kind == vkWord and v.wordKind == wkMetaWord and v.wordName == "const")
    # Player context's x and y should be the literal 800 and 600, not word refs.
    var foundPlayer = false
    for i in 0 ..< output.len - 2:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "player" and output[i + 2].kind == vkBlock:
        let ctx = output[i + 2].blockVals
        check ctx[0].wordName == "x" and ctx[1].kind == vkInteger and ctx[1].intVal == 800
        check ctx[2].wordName == "y" and ctx[3].kind == vkInteger and ctx[3].intVal == 600
        foundPlayer = true
    check foundPlayer

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

  test "field inside entity adds to context":
    let blk = @[
      ktgWord("target", wkSetWord), ktgWord("love2d", wkLitWord),
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
    let output = expand(blk)
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
      ktgWord("target", wkSetWord), ktgWord("love2d", wkLitWord),
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
    let output = expand(blk)
    var found = false
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/update" and output[i + 3].kind == vkBlock:
        let body = output[i + 3].blockVals
        check body.len == 3
        check body[0].kind == vkWord and body[0].wordKind == wkSetWord and
              body[0].wordName == "player/y"
        check body[1].kind == vkWord and body[1].wordKind == wkWord and
              body[1].wordName == "player/y"
        check body[2].kind == vkInteger and body[2].intVal == 5
        found = true
    check found

  test "state lifts to top-level set-words":
    let blk = @[
      ktgWord("target", wkSetWord), ktgWord("love2d", wkLitWord),
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
    let output = expand(blk)
    var sawPaused = false
    var sawScore = false
    var pausedIdx, scoreIdx, playerIdx = -1
    for i in 0 ..< output.len:
      let v = output[i]
      if v.kind == vkWord and v.wordKind == wkSetWord:
        if v.wordName == "paused?":
          sawPaused = true
          pausedIdx = i
        if v.wordName == "score":
          sawScore = true
          scoreIdx = i
        if v.wordName == "player":
          playerIdx = i
    check sawPaused
    check sawScore
    check pausedIdx < playerIdx
    check scoreIdx < playerIdx

  test "on-key lifts to match in love/keypressed":
    let blk = @[
      ktgWord("target", wkSetWord), ktgWord("love2d", wkLitWord),
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("on-key", wkWord), ktgString("space"),
        ktgBlock(@[ktgWord("paused?", wkSetWord), ktgLogic(true)]),
        ktgWord("on-key", wkWord), ktgString("escape"),
        ktgBlock(@[ktgWord("stop", wkWord)]),
      ]),
    ]
    let output = expand(blk)
    ## love/keypressed body should contain `match key [...]` with arms for each key.
    var found = false
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/keypressed" and output[i + 3].kind == vkBlock:
        let body = output[i + 3].blockVals
        ## body should start with: match key [arms block]
        check body.len == 3
        check body[0].kind == vkWord and body[0].wordName == "match"
        check body[1].kind == vkWord and body[1].wordName == "key"
        check body[2].kind == vkBlock
        let arms = body[2].blockVals
        ## arms should be: [["space"] [paused?: true] ["escape"] [stop] default []]
        ## 2 key arms * 2 tokens each = 4 tokens, plus default + [] = 6 tokens total
        check arms.len == 6
        check arms[0].kind == vkBlock  ## ["space"]
        check arms[0].blockVals.len == 1
        check arms[0].blockVals[0].kind == vkString and arms[0].blockVals[0].strVal == "space"
        check arms[1].kind == vkBlock  ## [paused?: true]
        check arms[2].kind == vkBlock
        check arms[2].blockVals[0].kind == vkString and arms[2].blockVals[0].strVal == "escape"
        check arms[3].kind == vkBlock  ## [stop]
        check arms[4].kind == vkWord and arms[4].wordName == "default"
        check arms[5].kind == vkBlock and arms[5].blockVals.len == 0
        found = true
    check found

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

# ---------------------------------------------------------------------------
# Three-layer golden runner for @game dialect files
# Layer 1: .ktg  -> _expanded.ktg  (dialect expansion, pretty-printed)
# Layer 2: .ktg  -> .lua            (full compile, handled by test_golden.nim)
# Layer 3: _expanded.ktg -> .lua   (expanded source compiles identically)
#
# Update goldens: KINTSUGI_UPDATE_GOLDENS=1 nim c -r tests/test_game_dialect.nim
# ---------------------------------------------------------------------------

proc gameSetupEval(): Evaluator =
  result = newEvaluator()
  result.registerNatives()

proc dryExpand(src: string): string =
  let source = applyUsingHeader(src)
  let ast = parseSource(source)
  let eval = gameSetupEval()
  let expanded = eval.preprocess(ast, forCompilation = true)
  prettyPrintBlock(expanded)

proc compileGameKtg(src, sourceDir: string): string =
  let source = applyUsingHeader(src)
  let ast = parseSource(source)
  let eval = gameSetupEval()
  let processed = eval.preprocess(ast, forCompilation = true)
  emitLua(processed, sourceDir)

proc normLF(s: string): string =
  s.replace("\r\n", "\n").replace("\r", "\n")

let gameGoldenDir = currentSourcePath().parentDir / "golden"
let updateGameGoldens = getEnv("KINTSUGI_UPDATE_GOLDENS") == "1"

suite "game dialect goldens (three layer)":
  for name in ["game_pong_stub"]:
    test name:
      let ktgPath = gameGoldenDir / (name & ".ktg")
      let expPath = gameGoldenDir / (name & "_expanded.ktg")
      let luaPath = gameGoldenDir / (name & ".lua")

      let src = readFile(ktgPath)
      let actualExpanded = normLF(dryExpand(src)) & "\n"
      let actualLua = normLF(compileGameKtg(src, gameGoldenDir))

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
