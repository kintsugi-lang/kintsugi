import ../core/types

type
  OnKeyForm* = object
    key*: KtgValue
    body*: seq[KtgValue]

  GameBackend* = object
    name*: string
    bindings*: seq[KtgValue]
    emitCallbacks*: proc(updateBody, drawBody: seq[KtgValue],
                         onKeys: seq[OnKeyForm]): seq[KtgValue]
    setColorCall*: proc(r, g, b: KtgValue): seq[KtgValue]
    drawRectCall*: proc(x, y, w, h: KtgValue): seq[KtgValue]
    printCall*: proc(text, x, y: KtgValue): seq[KtgValue]
    isKeyDown*: proc(key: KtgValue): seq[KtgValue]

proc bindingEntry*(name, luaPath, kind: string, arity: int = -1): seq[KtgValue] =
  result.add(ktgWord(name, wkWord))
  result.add(ktgString(luaPath))
  result.add(ktgWord(kind, wkLitWord))
  if arity >= 0:
    result.add(ktgInt(arity))
