import ../core/types

type
  GameBackend* = object
    name*: string
    bindings*: seq[KtgValue]
    loadShell*: proc(body: seq[KtgValue]): seq[KtgValue]
    updateShell*: proc(body: seq[KtgValue]): seq[KtgValue]
    drawShell*: proc(body: seq[KtgValue]): seq[KtgValue]
    keypressedShell*: proc(body: seq[KtgValue]): seq[KtgValue]
    setColorCall*: proc(r, g, b: KtgValue): seq[KtgValue]
    drawRectCall*: proc(x, y, w, h: KtgValue): seq[KtgValue]
    printCall*: proc(text, x, y: KtgValue): seq[KtgValue]
    quitCall*: proc(): seq[KtgValue]
    isKeyDown*: proc(key: KtgValue): seq[KtgValue]

proc bindingEntry*(name, luaPath, kind: string, arity: int = -1): seq[KtgValue] =
  result.add(ktgWord(name, wkWord))
  result.add(ktgString(luaPath))
  result.add(ktgWord(kind, wkLitWord))
  if arity >= 0:
    result.add(ktgInt(arity))
