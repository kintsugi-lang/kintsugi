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
