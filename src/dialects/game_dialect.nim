import std/tables
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
    quitCall*: proc(): seq[KtgValue]
    isKeyDown*: proc(key: KtgValue): seq[KtgValue]

proc love2dLoadShell(body: seq[KtgValue]): seq[KtgValue] = @[]
proc love2dUpdateShell(body: seq[KtgValue]): seq[KtgValue] = @[]
proc love2dDrawShell(body: seq[KtgValue]): seq[KtgValue] = @[]
proc love2dKeypressedShell(body: seq[KtgValue]): seq[KtgValue] = @[]
proc love2dSetColorCall(r, g, b: KtgValue): seq[KtgValue] = @[]
proc love2dDrawRectCall(x, y, w, h: KtgValue): seq[KtgValue] = @[]
proc love2dQuitCall(): seq[KtgValue] = @[]
proc love2dIsKeyDown(key: KtgValue): seq[KtgValue] = @[]

let love2dBackend* = GameBackend(
  name: "love2d",
  bindings: @[],
  loadShell: love2dLoadShell,
  updateShell: love2dUpdateShell,
  drawShell: love2dDrawShell,
  keypressedShell: love2dKeypressedShell,
  setColorCall: love2dSetColorCall,
  drawRectCall: love2dDrawRectCall,
  quitCall: love2dQuitCall,
  isKeyDown: love2dIsKeyDown,
)

var backends* = {"love2d": love2dBackend}.toTable

proc findTarget(blk: seq[KtgValue]): string =
  var i = 0
  while i < blk.len - 1:
    if blk[i].kind == vkWord and blk[i].wordKind == wkSetWord and
       blk[i].wordName == "target" and blk[i + 1].kind == vkWord and
       blk[i + 1].wordKind == wkLitWord:
      return blk[i + 1].wordName
    i += 1
  raise newException(ValueError, "@game: missing `target: 'name` field")

proc expandConstants(constantsBlock: seq[KtgValue]): seq[KtgValue] =
  var i = 0
  while i < constantsBlock.len - 1:
    if constantsBlock[i].kind == vkWord and
       constantsBlock[i].wordKind == wkSetWord:
      result.add(ktgWord("const", wkMetaWord))
      result.add(constantsBlock[i])
      result.add(constantsBlock[i + 1])
      i += 2
    else:
      i += 1

proc expandEntityComponents(body: seq[KtgValue]): seq[KtgValue] =
  var i = 0
  while i < body.len:
    let head = body[i]
    if head.kind == vkWord and head.wordKind == wkWord:
      case head.wordName
      of "pos":
        if i + 2 < body.len:
          result.add(ktgWord("x", wkSetWord)); result.add(body[i + 1])
          result.add(ktgWord("y", wkSetWord)); result.add(body[i + 2])
          i += 3
          continue
      of "rect":
        if i + 2 < body.len:
          result.add(ktgWord("w", wkSetWord)); result.add(body[i + 1])
          result.add(ktgWord("h", wkSetWord)); result.add(body[i + 2])
          i += 3
          continue
      of "color":
        if i + 3 < body.len:
          result.add(ktgWord("cr", wkSetWord)); result.add(body[i + 1])
          result.add(ktgWord("cg", wkSetWord)); result.add(body[i + 2])
          result.add(ktgWord("cb", wkSetWord)); result.add(body[i + 3])
          i += 4
          continue
      else:
        discard
    i += 1

proc expandScene(sceneName: string, sceneBody: seq[KtgValue],
                 backend: GameBackend): seq[KtgValue] =
  var i = 0
  while i < sceneBody.len:
    let head = sceneBody[i]
    if head.kind == vkWord and head.wordKind == wkWord and head.wordName == "entity" and
       i + 2 < sceneBody.len and sceneBody[i + 1].kind == vkWord and
       sceneBody[i + 1].wordKind == wkWord and sceneBody[i + 2].kind == vkBlock:
      let entName = sceneBody[i + 1].wordName
      let components = expandEntityComponents(sceneBody[i + 2].blockVals)
      result.add(ktgWord(entName, wkSetWord))
      result.add(ktgWord("context", wkWord))
      result.add(ktgBlock(components))
      i += 3
    else:
      i += 1

proc expand*(blk: seq[KtgValue]): seq[KtgValue] =
  let targetName = findTarget(blk)
  if not backends.hasKey(targetName):
    raise newException(ValueError,
      "@game: unknown target '" & targetName & "'")
  let backend = backends[targetName]

  for v in backend.bindings:
    result.add(v)

  var i = 0
  while i < blk.len:
    let v = blk[i]
    if v.kind == vkWord and v.wordKind == wkSetWord and v.wordName == "target":
      i += 2
    elif v.kind == vkWord and v.wordKind == wkWord and v.wordName == "constants" and
         i + 1 < blk.len and blk[i + 1].kind == vkBlock:
      for c in expandConstants(blk[i + 1].blockVals):
        result.add(c)
      i += 2
    elif v.kind == vkWord and v.wordKind == wkWord and v.wordName == "scene" and
         i + 2 < blk.len and blk[i + 1].kind == vkWord and
         blk[i + 1].wordKind == wkLitWord and blk[i + 2].kind == vkBlock:
      for s in expandScene(blk[i + 1].wordName, blk[i + 2].blockVals, backend):
        result.add(s)
      i += 3
    elif v.kind == vkWord and v.wordKind == wkWord and v.wordName == "go":
      i += 2
    else:
      i += 1
