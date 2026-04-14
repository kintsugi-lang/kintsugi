import ../core/types
import game_backend

proc playdateLoadShell(body: seq[KtgValue]): seq[KtgValue] =
  body

proc playdateUpdateShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgWord("playdate/update", wkSetWord),
    ktgWord("function", wkWord),
    ktgBlock(@[]),
    ktgBlock(body),
  ]

proc playdateDrawShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgWord("playdate/draw", wkSetWord),
    ktgWord("function", wkWord),
    ktgBlock(@[]),
    ktgBlock(body),
  ]

proc playdateKeypressedShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgWord("playdate/keypressed", wkSetWord),
    ktgWord("function", wkWord),
    ktgBlock(@[ktgWord("key", wkWord)]),
    ktgBlock(body),
  ]

proc playdateSetColorCall(r, g, b: KtgValue): seq[KtgValue] =
  @[]

proc playdateDrawRectCall(x, y, w, h: KtgValue): seq[KtgValue] =
  @[ktgWord("playdate/graphics/fillRect", wkWord), x, y, w, h]

proc playdateQuitCall(): seq[KtgValue] =
  @[ktgWord("playdate/system/exit", wkWord)]

proc playdateIsKeyDown(key: KtgValue): seq[KtgValue] =
  @[ktgWord("playdate/buttonIsDown", wkWord), key]

proc playdateBindings(): seq[KtgValue] =
  var entries: seq[KtgValue]
  for v in bindingEntry("playdate/graphics/fillRect", "playdate.graphics.fillRect", "call", 4): entries.add(v)
  for v in bindingEntry("playdate/graphics/drawText", "playdate.graphics.drawText", "call", 3): entries.add(v)
  for v in bindingEntry("playdate/system/exit",       "playdate.system.exit",       "call", 0): entries.add(v)
  for v in bindingEntry("playdate/buttonIsDown",      "playdate.buttonIsDown",      "call", 1): entries.add(v)
  for v in bindingEntry("playdate/update",     "playdate.update",     "assign"): entries.add(v)
  for v in bindingEntry("playdate/draw",       "playdate.draw",       "assign"): entries.add(v)
  for v in bindingEntry("playdate/keypressed", "playdate.keypressed", "assign"): entries.add(v)
  @[ktgWord("bindings", wkWord), ktgBlock(entries)]

let playdateBackend* = GameBackend(
  name: "playdate",
  bindings: playdateBindings(),
  loadShell: playdateLoadShell,
  updateShell: playdateUpdateShell,
  drawShell: playdateDrawShell,
  keypressedShell: playdateKeypressedShell,
  setColorCall: playdateSetColorCall,
  drawRectCall: playdateDrawRectCall,
  quitCall: playdateQuitCall,
  isKeyDown: playdateIsKeyDown,
)
