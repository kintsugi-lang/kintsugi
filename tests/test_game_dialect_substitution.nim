import std/unittest
import ../src/core/types
import ../src/dialects/game_dialect

suite "substituteSelf error cases":
  test "bare self raises":
    let body = @[ktgWord("self", wkWord)]
    expect(ValueError):
      discard substituteSelf(body, "player")

  test "bare self inside nested block raises":
    let body = @[
      ktgWord("if", wkWord),
      ktgBlock(@[ktgWord("self", wkWord)]),
    ]
    expect(ValueError):
      discard substituteSelf(body, "player")

suite "assertNoSelf error cases":
  test "self/field in on-key handler raises":
    let blk = @[
      ktgWord("target", wkSetWord), ktgWord("love2d", wkLitWord),
      ktgWord("scene", wkWord), ktgWord("main", wkLitWord),
      ktgBlock(@[
        ktgWord("on-key", wkWord), ktgString("space"),
        ktgBlock(@[ktgWord("self/x", wkSetWord), ktgInt(0)]),
      ]),
    ]
    expect(ValueError):
      discard expand(blk)

suite "substituteSelf nested shapes":
  test "if body":
    let body = @[
      ktgWord("if", wkWord),
      ktgWord("cond", wkWord),
      ktgBlock(@[ktgWord("self/x", wkSetWord), ktgInt(1)]),
    ]
    let output = substituteSelf(body, "player")
    let inner = output[2].blockVals
    check inner[0].kind == vkWord and inner[0].wordKind == wkSetWord
    check inner[0].wordName == "player/x"

  test "match arm body":
    let body = @[
      ktgWord("match", wkWord),
      ktgWord("v", wkWord),
      ktgBlock(@[
        ktgBlock(@[ktgInt(1)]),
        ktgBlock(@[ktgWord("self/y", wkSetWord), ktgInt(2)]),
      ]),
    ]
    let output = substituteSelf(body, "ball")
    let arms = output[2].blockVals
    let armBody = arms[1].blockVals
    check armBody[0].wordName == "ball/y"

  test "loop body":
    let body = @[
      ktgWord("loop", wkWord),
      ktgBlock(@[
        ktgWord("for", wkWord),
        ktgBlock(@[ktgWord("i", wkWord)]),
        ktgWord("in", wkWord),
        ktgBlock(@[]),
        ktgWord("do", wkWord),
        ktgBlock(@[
          ktgWord("self/count", wkSetWord),
          ktgWord("self/count", wkWord),
          ktgWord("+", wkWord),
          ktgWord("i", wkWord),
        ]),
      ]),
    ]
    let output = substituteSelf(body, "emitter")
    let loopBlk = output[1].blockVals
    let doBlk = loopBlk[loopBlk.len - 1].blockVals
    check doBlk[0].kind == vkWord and doBlk[0].wordKind == wkSetWord
    check doBlk[0].wordName == "emitter/count"
    check doBlk[1].wordName == "emitter/count"

  test "either branches":
    let body = @[
      ktgWord("either", wkWord),
      ktgWord("cond", wkWord),
      ktgBlock(@[ktgWord("self/a", wkSetWord), ktgInt(1)]),
      ktgBlock(@[ktgWord("self/a", wkSetWord), ktgInt(2)]),
    ]
    let output = substituteSelf(body, "p")
    check output[2].blockVals[0].wordName == "p/a"
    check output[3].blockVals[0].wordName == "p/a"

  test "paren recursion":
    let body = @[
      ktgParen(@[ktgWord("self/x", wkWord), ktgWord("+", wkWord), ktgInt(1)]),
    ]
    let output = substituteSelf(body, "player")
    let pvals = output[0].parenVals
    check pvals[0].wordName == "player/x"

  test "non-mutating input preserved":
    let original = @[ktgWord("self/x", wkSetWord), ktgInt(1)]
    let copy = original
    discard substituteSelf(original, "player")
    check original[0].wordName == copy[0].wordName
