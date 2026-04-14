import ../core/types
import game_backend

proc playdateEmitCallbacks(updateBody, drawBody: seq[KtgValue],
                           onKeys: seq[OnKeyForm]): seq[KtgValue] =
  ## Playdate has ONE callback: playdate.update(). Fold update + draw +
  ## key-event polling into a single function body.
  var body: seq[KtgValue] = @[]
  for v in updateBody:
    body.add(v)
  for v in drawBody:
    body.add(v)
  for form in onKeys:
    body.add(ktgWord("if", wkWord))
    body.add(ktgWord("playdate/buttonJustPressed", wkWord))
    body.add(form.key)
    body.add(ktgBlock(form.body))

  result.add(ktgWord("playdate/update", wkSetWord))
  result.add(ktgWord("function", wkWord))
  result.add(ktgBlock(@[]))
  result.add(ktgBlock(body))

proc playdateSetColorCall(r, g, b: KtgValue): seq[KtgValue] =
  @[]  ## monochrome: setColor is a no-op

proc playdateDrawRectCall(x, y, w, h: KtgValue): seq[KtgValue] =
  @[ktgWord("playdate/graphics/fillRect", wkWord), x, y, w, h]

proc playdatePrintCall(text, x, y: KtgValue): seq[KtgValue] =
  @[ktgWord("playdate/graphics/drawText", wkWord), text, x, y]

proc playdateIsKeyDown(key: KtgValue): seq[KtgValue] =
  @[ktgWord("playdate/buttonIsPressed", wkWord), key]

proc playdateBindings(): seq[KtgValue] =
  var entries: seq[KtgValue]
  for v in bindingEntry("playdate/graphics/fillRect", "playdate.graphics.fillRect", "call", 4): entries.add(v)
  for v in bindingEntry("playdate/graphics/drawText", "playdate.graphics.drawText", "call", 3): entries.add(v)
  for v in bindingEntry("playdate/buttonIsPressed",    "playdate.buttonIsPressed",   "call", 1): entries.add(v)
  for v in bindingEntry("playdate/buttonJustPressed",  "playdate.buttonJustPressed", "call", 1): entries.add(v)
  for v in bindingEntry("playdate/update", "playdate.update", "assign"): entries.add(v)
  @[ktgWord("bindings", wkWord), ktgBlock(entries)]

let playdateBackend* = GameBackend(
  name: "playdate",
  bindings: playdateBindings(),
  emitCallbacks: playdateEmitCallbacks,
  setColorCall: playdateSetColorCall,
  drawRectCall: playdateDrawRectCall,
  printCall: playdatePrintCall,
  isKeyDown: playdateIsKeyDown,
)
