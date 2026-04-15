import std/unittest
import ../src/core/types
import ../src/dialects/game_dialect

suite "substituteSelf bare self":
  test "bare self substitutes to entity name":
    ## `reset-ball self 1` inside `entity ball [...]` becomes
    ## `reset-ball ball 1` so the user helper receives the entity.
    let body = @[
      ktgWord("reset-ball", wkWord),
      ktgWord("self", wkWord),
      ktgInt(1),
    ]
    let output = substituteSelf(body, "ball")
    check output[0].wordName == "reset-ball"
    check output[1].kind == vkWord and output[1].wordKind == wkWord
    check output[1].wordName == "ball"
    check output[2].intVal == 1

  test "bare self inside nested block also substitutes":
    let body = @[
      ktgWord("if", wkWord),
      ktgBlock(@[ktgWord("destroy", wkWord), ktgWord("self", wkWord)]),
    ]
    let output = substituteSelf(body, "player")
    let inner = output[1].blockVals
    check inner[1].wordName == "player"

  test "self as set-word raises (cannot reassign entity)":
    let body = @[ktgWord("self", wkSetWord), ktgInt(1)]
    expect(ValueError):
      discard substituteSelf(body, "player")

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

suite "substituteIt":
  test "simple it/field rewritten":
    let body = @[ktgWord("it/x", wkWord)]
    let output = substituteIt(body, "ball")
    check output[0].kind == vkWord and output[0].wordKind == wkWord
    check output[0].wordName == "ball/x"

  test "set-word kind preserved":
    let body = @[ktgWord("it/y", wkSetWord), ktgInt(0)]
    let output = substituteIt(body, "paddle")
    check output[0].wordKind == wkSetWord
    check output[0].wordName == "paddle/y"

  test "bare it raises":
    expect(ValueError):
      discard substituteIt(@[ktgWord("it", wkWord)], "ball")

  test "recurses into blocks":
    let body = @[
      ktgWord("if", wkWord),
      ktgBlock(@[ktgWord("it/x", wkSetWord), ktgInt(1)]),
    ]
    let output = substituteIt(body, "ball")
    check output[1].blockVals[0].wordName == "ball/x"

  test "recurses into parens":
    let body = @[
      ktgParen(@[ktgWord("it/x", wkWord), ktgWord("+", wkWord), ktgInt(1)]),
    ]
    let output = substituteIt(body, "ball")
    check output[0].parenVals[0].wordName == "ball/x"

suite "assertNoIt":
  test "bare it raises in assertNoIt":
    expect(ValueError):
      assertNoIt(@[ktgWord("it", wkWord)], "draw block")

  test "it/field raises in assertNoIt":
    expect(ValueError):
      assertNoIt(@[ktgWord("it/x", wkWord)], "draw block")

suite "substitution result independence":
  test "substituteSelf: mutating result does not affect input":
    let original = @[ktgBlock(@[ktgWord("self/x", wkSetWord), ktgInt(1)])]
    let output = substituteSelf(original, "player")
    ## Mutate the returned seq by replacing an element.
    var mut = output
    mut[0] = ktgInt(999)
    ## Original must be unchanged.
    check original[0].kind == vkBlock
    check original[0].blockVals[0].wordName == "self/x"

  test "substituteIt: mutating result does not affect input":
    let original = @[ktgBlock(@[ktgWord("it/y", wkSetWord), ktgInt(2)])]
    let output = substituteIt(original, "ball")
    var mut = output
    mut[0] = ktgInt(999)
    check original[0].kind == vkBlock
    check original[0].blockVals[0].wordName == "it/y"

  test "substituteSelf: input's nested block is not aliased":
    let innerBlock = ktgBlock(@[ktgWord("self/a", wkWord)])
    let original = @[ktgWord("wrap", wkWord), innerBlock]
    let output = substituteSelf(original, "p")
    ## output's nested block should have "p/a", original should still have "self/a".
    check output[1].blockVals[0].wordName == "p/a"
    check original[1].blockVals[0].wordName == "self/a"
