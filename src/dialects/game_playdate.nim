import ../core/types
import game_backend

proc playdateEmitCallbacks(updateBody, drawBody: seq[KtgValue]): seq[KtgValue] =
  ## Playdate has ONE callback: playdate.update(). Fold update + draw
  ## into a single function body.
  var body: seq[KtgValue] = @[]
  for v in updateBody:
    body.add(v)
  for v in drawBody:
    body.add(v)

  result.add(ktgWord("playdate/update", wkSetWord))
  result.add(ktgWord("function", wkWord))
  result.add(ktgBlock(@[]))
  result.add(ktgBlock(body))

proc playdateBindings(): seq[KtgValue] =
  var entries: seq[KtgValue]
  for v in bindingEntry("playdate/graphics/fillRect", "playdate.graphics.fillRect", "call", 4): entries.add(v)
  for v in bindingEntry("playdate/graphics/drawText", "playdate.graphics.drawText", "call", 3): entries.add(v)
  for v in bindingEntry("playdate/buttonIsPressed",    "playdate.buttonIsPressed",   "call", 1): entries.add(v)
  for v in bindingEntry("playdate/buttonJustPressed",  "playdate.buttonJustPressed", "call", 1): entries.add(v)
  for v in bindingEntry("playdate/update", "playdate.update", "assign"): entries.add(v)
  ## Button constants - dev references these directly from @game update/draw bodies.
  for (ktgName, luaPath) in @[
    ("playdate/kButtonA",     "playdate.kButtonA"),
    ("playdate/kButtonB",     "playdate.kButtonB"),
    ("playdate/kButtonUp",    "playdate.kButtonUp"),
    ("playdate/kButtonDown",  "playdate.kButtonDown"),
    ("playdate/kButtonLeft",  "playdate.kButtonLeft"),
    ("playdate/kButtonRight", "playdate.kButtonRight"),
  ]:
    for v in bindingEntry(ktgName, luaPath, "const"): entries.add(v)
  @[ktgWord("bindings", wkWord), ktgBlock(entries)]

proc playdatePrelude(): seq[KtgValue] =
  ## pdc preprocessor directives - must appear verbatim, not as function calls.
  @[
    ktgWord("raw", wkWord),
    ktgString("import \"CoreLibs/graphics\"\n" &
              "import \"CoreLibs/sprites\"\n" &
              "import \"CoreLibs/timer\""),
  ]

proc playdateDrawEntity(name: string): seq[KtgValue] =
  ## Emits: playdate.graphics.fillRect(n.x, n.y, n.w, n.h)
  ## Monochrome: no setColor.
  @[
    ktgWord("playdate/graphics/fillRect", wkWord),
    ktgWord(name & "/x", wkWord),
    ktgWord(name & "/y", wkWord),
    ktgWord(name & "/w", wkWord),
    ktgWord(name & "/h", wkWord),
  ]

proc playdateFramePrelude(): seq[KtgValue] =
  ## Top-of-update shims: Playdate's update() has no dt parameter, and the
  ## framebuffer is not auto-cleared. Emit both as verbatim Lua so we don't
  ## need bindings for every detail.
  @[
    ktgWord("raw", wkWord),
    ktgString("local dt = 1/30\nplaydate.graphics.clear()"),
  ]

let playdateBackend* = GameBackend(
  name: "playdate",
  bindings: playdateBindings(),
  prelude: playdatePrelude(),
  framePrelude: playdateFramePrelude(),
  storesColor: false,
  emitCallbacks: playdateEmitCallbacks,
  drawEntity: playdateDrawEntity,
)
