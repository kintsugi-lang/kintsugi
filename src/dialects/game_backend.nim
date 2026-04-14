import ../core/types

type
  GameBackend* = object
    name*: string
    bindings*: seq[KtgValue]
    prelude*: seq[KtgValue]       ## emitted at top-of-file, after bindings
    framePrelude*: seq[KtgValue]  ## prepended to update body each frame
    storesColor*: bool            ## if false, `color r g b` is dropped at extract time
    emitCallbacks*: proc(updateBody, drawBody: seq[KtgValue]): seq[KtgValue]
    drawEntity*: proc(name: string): seq[KtgValue]
      ## Target-optimal auto-rect draw for an entity context. Receives the
      ## entity's name (e.g. "player") and emits the KtgValue sequence that
      ## draws it, using whatever direct target bindings produce the cleanest Lua.

proc bindingEntry*(name, luaPath, kind: string, arity: int = -1): seq[KtgValue] =
  result.add(ktgWord(name, wkWord))
  result.add(ktgString(luaPath))
  result.add(ktgWord(kind, wkLitWord))
  if arity >= 0:
    result.add(ktgInt(arity))
