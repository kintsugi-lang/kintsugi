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
        ## 8 fields: x y w h cr cg cb _alive = 16 tokens
        check ctx.len == 16
        check ctx[0].wordName == "x" and ctx[1].intVal == 20
        check ctx[8].wordName == "cr"
        check ctx[14].wordName == "_alive"
        check ctx[15].kind == vkLogic and ctx[15].boolVal == true
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
        ## x y w h _alive = 10 tokens (no cr/cg/cb)
        check ctx.len == 10
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
    var sawSetColor, sawRect, sawPlayerCr, sawPlayerX = false
    proc scan(vs: seq[KtgValue]) =
      for v in vs:
        if v.kind == vkWord and v.wordKind == wkWord:
          case v.wordName
          of "love/graphics/setColor": sawSetColor = true
          of "love/graphics/rectangle": sawRect = true
          of "player/cr": sawPlayerCr = true
          of "player/x": sawPlayerX = true
          else: discard
        elif v.kind == vkBlock: scan(v.blockVals)
        elif v.kind == vkParen: scan(v.parenVals)
    scan(output)
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
    ## Locate the love/draw function body and scan only inside it -
    ## the top-level bindings block legitimately contains the string
    ## "love/graphics/setColor" as a binding entry.
    var drawBodyVals: seq[KtgValue] = @[]
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/draw" and output[i + 3].kind == vkBlock:
        drawBodyVals = output[i + 3].blockVals
    var sawSetColor, sawRect, sawPrint, sawPlayerX, sawPlayerY = false
    proc scan(vs: seq[KtgValue]) =
      for v in vs:
        if v.kind == vkWord:
          case v.wordName
          of "love/graphics/setColor": sawSetColor = true
          of "love/graphics/rectangle": sawRect = true
          of "love/graphics/print": sawPrint = true
          of "player/x": sawPlayerX = true
          of "player/y": sawPlayerY = true
          else: discard
        elif v.kind == vkBlock: scan(v.blockVals)
        elif v.kind == vkParen: scan(v.parenVals)
    scan(drawBodyVals)
    ## No auto-rect in the draw body: the custom draw replaced it.
    check not sawSetColor
    check not sawRect
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
    ## Update body is now wrapped in `if player/_alive [<statements>]`.
    ## Recurse into the guarded block to find the substituted self/y reference.
    var sawPlayerYSet, sawPlayerYRef = false
    proc scan(vs: seq[KtgValue]) =
      for j in 0 ..< vs.len:
        let v = vs[j]
        if v.kind == vkWord and v.wordKind == wkSetWord and v.wordName == "player/y":
          sawPlayerYSet = true
        if v.kind == vkWord and v.wordKind == wkWord and v.wordName == "player/y":
          sawPlayerYRef = true
        if v.kind == vkBlock: scan(v.blockVals)
        if v.kind == vkParen: scan(v.parenVals)
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/update" and output[i + 3].kind == vkBlock:
        scan(output[i + 3].blockVals)
    check sawPlayerYSet
    check sawPlayerYRef

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

  test "collide/using emits predicate call instead of AABB":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("ball", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(8), ktgInt(8),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
        ]),
        ktgWord("entity", wkWord), ktgWord("target", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(50), ktgInt(50),
          ktgWord("rect", wkWord), ktgInt(8), ktgInt(8),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
          ktgWord("tags", wkWord), ktgBlock(@[ktgWord("hit", wkWord)]),
        ]),
        ktgWord("collide/using", wkWord),
        ktgWord("ball", wkWord),
        ktgWord("hit", wkLitWord),
        ktgWord("circle-hit?", wkWord),
        ktgBlock(@[ktgWord("ball/x", wkSetWord), ktgInt(0)]),
      ]),
    ]
    let output = expand(blk, "love2d")
    ## Positive check: the tight `circle-hit? ball target` trio must
    ## appear as three consecutive tokens inside a paren (the predicate call).
    var sawPredCall = false
    ## Negative check: AABB emission uses the `<` op between field refs.
    ## When /using replaces AABB, no `<` ops should appear in the update body.
    var sawLtOp = false
    proc scan(vs: seq[KtgValue]) =
      for j in 0 ..< vs.len:
        let v = vs[j]
        if v.kind == vkOp and v.opSymbol == "<":
          sawLtOp = true
        if v.kind == vkWord and v.wordName == "circle-hit?" and
           j + 2 < vs.len and
           vs[j + 1].kind == vkWord and vs[j + 1].wordName == "ball" and
           vs[j + 2].kind == vkWord and vs[j + 2].wordName == "target":
          sawPredCall = true
        if v.kind == vkBlock: scan(v.blockVals)
        if v.kind == vkParen: scan(v.parenVals)
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/update" and output[i + 3].kind == vkBlock:
        scan(output[i + 3].blockVals)
    check sawPredCall
    check not sawLtOp

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

suite "game dialect destroy / _alive":
  test "every entity context includes _alive true field":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(1), ktgInt(1),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var sawAlive = false
    for i in 0 ..< output.len - 2:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "player" and output[i + 2].kind == vkBlock:
        let ctx = output[i + 2].blockVals
        for j in 0 ..< ctx.len - 1:
          if ctx[j].kind == vkWord and ctx[j].wordKind == wkSetWord and
             ctx[j].wordName == "_alive":
            check ctx[j + 1].kind == vkLogic and ctx[j + 1].boolVal == true
            sawAlive = true
    check sawAlive

  test "reserved _alive field name errors when user declares":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(1), ktgInt(1),
          ktgWord("field", wkWord), ktgWord("_alive", wkWord), ktgLogic(false),
        ]),
      ]),
    ]
    expect(ValueError):
      discard expand(blk, "love2d")

  test "destroy self rewrites to self/_alive: false before self substitution":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(1), ktgInt(1),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
          ktgWord("update", wkWord),
          ktgBlock(@[
            ktgWord("destroy", wkWord), ktgWord("self", wkWord),
          ]),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    ## Inside love/update body, we should find `player/_alive: false`.
    var sawPlayerAliveFalse = false
    proc scan(vs: seq[KtgValue]) =
      for j in 0 ..< vs.len:
        let v = vs[j]
        if j + 1 < vs.len and v.kind == vkWord and v.wordKind == wkSetWord and
           v.wordName == "player/_alive" and
           vs[j + 1].kind == vkLogic and vs[j + 1].boolVal == false:
          sawPlayerAliveFalse = true
        if v.kind == vkBlock: scan(v.blockVals)
        if v.kind == vkParen: scan(v.parenVals)
    scan(output)
    check sawPlayerAliveFalse
    ## The bare `destroy`/`self` pair should be gone.
    var sawBareDestroy = false
    proc scanDestroy(vs: seq[KtgValue]) =
      for v in vs:
        if v.kind == vkWord and v.wordName == "destroy":
          sawBareDestroy = true
        elif v.kind == vkBlock: scanDestroy(v.blockVals)
        elif v.kind == vkParen: scanDestroy(v.parenVals)
    scanDestroy(output)
    check not sawBareDestroy

  test "per-entity update body wraps in if <entity>/_alive":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(1), ktgInt(1),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
          ktgWord("update", wkWord),
          ktgBlock(@[ktgWord("self/x", wkSetWord), ktgInt(5)]),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    ## love/update body should contain: if player/_alive [player/x: 5]
    var sawGuardedUpdate = false
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/update" and output[i + 3].kind == vkBlock:
        let body = output[i + 3].blockVals
        ## Look for the if/player_alive/block sequence.
        for j in 0 ..< body.len - 2:
          if body[j].kind == vkWord and body[j].wordName == "if" and
             body[j + 1].kind == vkWord and body[j + 1].wordName == "player/_alive" and
             body[j + 2].kind == vkBlock:
            sawGuardedUpdate = true
    check sawGuardedUpdate

  test "per-entity draw wraps in if <entity>/_alive":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("player", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(1), ktgInt(1),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
        ]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var sawGuardedDraw = false
    for i in 0 ..< output.len - 3:
      if output[i].kind == vkWord and output[i].wordKind == wkSetWord and
         output[i].wordName == "love/draw" and output[i + 3].kind == vkBlock:
        let body = output[i + 3].blockVals
        for j in 0 ..< body.len - 2:
          if body[j].kind == vkWord and body[j].wordName == "if" and
             body[j + 1].kind == vkWord and body[j + 1].wordName == "player/_alive" and
             body[j + 2].kind == vkBlock:
            sawGuardedDraw = true
    check sawGuardedDraw

  test "collide AABB includes alive checks in all? block":
    let blk = @[
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("entity", wkWord), ktgWord("ball", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(0), ktgInt(0),
          ktgWord("rect", wkWord), ktgInt(4), ktgInt(4),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
        ]),
        ktgWord("entity", wkWord), ktgWord("paddle", wkWord),
        ktgBlock(@[
          ktgWord("pos", wkWord), ktgInt(10), ktgInt(10),
          ktgWord("rect", wkWord), ktgInt(4), ktgInt(4),
          ktgWord("color", wkWord), ktgInt(1), ktgInt(1), ktgInt(1),
          ktgWord("tags", wkWord), ktgBlock(@[ktgWord("hit", wkWord)]),
        ]),
        ktgWord("collide", wkWord), ktgWord("ball", wkWord), ktgWord("hit", wkLitWord),
        ktgBlock(@[ktgWord("destroy", wkWord), ktgWord("ball", wkWord)]),
      ]),
    ]
    let output = expand(blk, "love2d")
    var sawBothAlive = false
    proc scan(vs: seq[KtgValue]) =
      for v in vs:
        if v.kind == vkBlock:
          var hasBallAlive, hasPaddleAlive = false
          for x in v.blockVals:
            if x.kind == vkWord and x.wordName == "ball/_alive": hasBallAlive = true
            if x.kind == vkWord and x.wordName == "paddle/_alive": hasPaddleAlive = true
          if hasBallAlive and hasPaddleAlive:
            sawBothAlive = true
          scan(v.blockVals)
        elif v.kind == vkParen:
          scan(v.parenVals)
    scan(output)
    check sawBothAlive

suite "game dialect @component macros":
  test "user @component expands into dialect vocabulary inside entity body":
    ## @component health adds an hp field and an update hook.
    ## The entity body references it as `health 10` which must
    ## expand at @game parse time into field+update forms.
    let src = """
      Kintsugi [name: 'comptest]
      @macro health: function [amount [integer!]] [@compose [
        field hp (amount)
        field max-hp (amount)
      ]]
      @game [
        scene 'main [
          entity player [
            pos 20 40
            rect 12 12
            color 1 1 1
            health 25
          ]
        ]
      ]
    """
    let ast = parseSource(src)
    let eval = setupEvaluator()
    let processed = eval.preprocess(ast, forCompilation = true, target = "love2d")
    ## The expansion should produce an entity context where hp == 25.
    var sawHp, sawMaxHp = false
    for i in 0 ..< processed.len - 2:
      if processed[i].kind == vkWord and processed[i].wordKind == wkSetWord and
         processed[i].wordName == "player" and processed[i + 2].kind == vkBlock:
        let ctx = processed[i + 2].blockVals
        for j in 0 ..< ctx.len - 1:
          if ctx[j].kind == vkWord and ctx[j].wordKind == wkSetWord:
            if ctx[j].wordName == "hp" and ctx[j + 1].intVal == 25:
              sawHp = true
            if ctx[j].wordName == "max-hp" and ctx[j + 1].intVal == 25:
              sawMaxHp = true
    check sawHp
    check sawMaxHp

  test "@component is sugar for @macro ... function ... @compose":
    ## @component should desugar to a registered macro that produces
    ## entity-body vocabulary via @compose.
    let src = """
      Kintsugi [name: 'sugar]
      @component health: [amount [integer!]] [
        field hp (amount)
        field max-hp (amount)
      ]
      @game [
        scene 'main [
          entity player [
            pos 10 20  rect 4 4  color 1 1 1
            health 7
          ]
        ]
      ]
    """
    let ast = parseSource(src)
    let eval = setupEvaluator()
    let processed = eval.preprocess(ast, forCompilation = true, target = "love2d")
    var sawHp, sawMaxHp = false
    for i in 0 ..< processed.len - 2:
      if processed[i].kind == vkWord and processed[i].wordKind == wkSetWord and
         processed[i].wordName == "player" and processed[i + 2].kind == vkBlock:
        let ctx = processed[i + 2].blockVals
        for j in 0 ..< ctx.len - 1:
          if ctx[j].kind == vkWord and ctx[j].wordKind == wkSetWord:
            if ctx[j].wordName == "hp" and ctx[j + 1].intVal == 7:
              sawHp = true
            if ctx[j].wordName == "max-hp" and ctx[j + 1].intVal == 7:
              sawMaxHp = true
    check sawHp
    check sawMaxHp

  test "non-macro words in entity body pass through unchanged":
    ## Same setup as before but no macros involved. The existing dialect
    ## vocabulary (pos/rect/color/field) still works when a macro expander
    ## callback is supplied but doesn't find anything to expand.
    let src = """
      Kintsugi [name: 'passthrough]
      @game [
        scene 'main [
          entity player [
            pos 10 20  rect 4 4  color 1 1 1
            field hp 5
          ]
        ]
      ]
    """
    let ast = parseSource(src)
    let eval = setupEvaluator()
    let processed = eval.preprocess(ast, forCompilation = true, target = "love2d")
    var found = false
    for i in 0 ..< processed.len - 2:
      if processed[i].kind == vkWord and processed[i].wordKind == wkSetWord and
         processed[i].wordName == "player" and processed[i + 2].kind == vkBlock:
        let ctx = processed[i + 2].blockVals
        check ctx[0].wordName == "x" and ctx[1].intVal == 10
        for j in 0 ..< ctx.len - 1:
          if ctx[j].kind == vkWord and ctx[j].wordName == "hp":
            check ctx[j + 1].intVal == 5
            found = true
    check found

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
