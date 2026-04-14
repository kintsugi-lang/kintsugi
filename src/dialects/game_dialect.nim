import std/[tables, strutils]
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

proc love2dLoadShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgWord("love/load", wkSetWord),
    ktgWord("function", wkWord),
    ktgBlock(@[]),
    ktgBlock(body),
  ]

proc love2dUpdateShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgWord("love/update", wkSetWord),
    ktgWord("function", wkWord),
    ktgBlock(@[ktgWord("dt", wkWord)]),
    ktgBlock(body),
  ]

proc love2dDrawShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgWord("love/draw", wkSetWord),
    ktgWord("function", wkWord),
    ktgBlock(@[]),
    ktgBlock(body),
  ]

proc love2dKeypressedShell(body: seq[KtgValue]): seq[KtgValue] =
  @[
    ktgWord("love/keypressed", wkSetWord),
    ktgWord("function", wkWord),
    ktgBlock(@[ktgWord("key", wkWord)]),
    ktgBlock(body),
  ]

proc love2dSetColorCall(r, g, b: KtgValue): seq[KtgValue] =
  @[ktgWord("love/graphics/setColor", wkWord), r, g, b, ktgInt(1)]

proc love2dDrawRectCall(x, y, w, h: KtgValue): seq[KtgValue] =
  @[ktgWord("love/graphics/rectangle", wkWord), ktgWord("fill", wkLitWord), x, y, w, h]

proc love2dQuitCall(): seq[KtgValue] =
  @[ktgWord("love/event/quit", wkWord)]

proc love2dIsKeyDown(key: KtgValue): seq[KtgValue] =
  @[ktgWord("love/keyboard/isDown", wkWord), key]

proc bindingEntry(name, luaPath, kind: string, arity: int = -1): seq[KtgValue] =
  result.add(ktgWord(name, wkWord))
  result.add(ktgString(luaPath))
  result.add(ktgWord(kind, wkLitWord))
  if arity >= 0:
    result.add(ktgInt(arity))

proc love2dBindings(): seq[KtgValue] =
  var entries: seq[KtgValue]
  for v in bindingEntry("love/graphics/setColor",  "love.graphics.setColor",  "call", 4): entries.add(v)
  for v in bindingEntry("love/graphics/rectangle", "love.graphics.rectangle", "call", 5): entries.add(v)
  for v in bindingEntry("love/event/quit",          "love.event.quit",          "call", 0): entries.add(v)
  for v in bindingEntry("love/keyboard/isDown",     "love.keyboard.isDown",     "call", 1): entries.add(v)
  for v in bindingEntry("love/load",       "love.load",       "assign"): entries.add(v)
  for v in bindingEntry("love/update",     "love.update",     "assign"): entries.add(v)
  for v in bindingEntry("love/draw",       "love.draw",       "assign"): entries.add(v)
  for v in bindingEntry("love/keypressed", "love.keypressed", "assign"): entries.add(v)
  @[ktgWord("bindings", wkWord), ktgBlock(entries)]

let love2dBackend* = GameBackend(
  name: "love2d",
  bindings: love2dBindings(),
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

proc collectConstants(constantsBlock: seq[KtgValue]): Table[string, KtgValue] =
  var i = 0
  while i < constantsBlock.len - 1:
    if constantsBlock[i].kind == vkWord and
       constantsBlock[i].wordKind == wkSetWord:
      result[constantsBlock[i].wordName] = constantsBlock[i + 1]
      i += 2
    else:
      i += 1

proc inlineConstants(vals: seq[KtgValue],
                     consts: Table[string, KtgValue]): seq[KtgValue] =
  result = newSeq[KtgValue](vals.len)
  for idx, v in vals:
    case v.kind
    of vkWord:
      if v.wordKind == wkWord and consts.hasKey(v.wordName):
        result[idx] = consts[v.wordName]
      else:
        result[idx] = v
    of vkBlock:
      result[idx] = ktgBlock(inlineConstants(v.blockVals, consts))
    of vkParen:
      result[idx] = ktgParen(inlineConstants(v.parenVals, consts))
    else:
      result[idx] = v

proc substituteQuit*(vals: seq[KtgValue], backend: GameBackend): seq[KtgValue] =
  for v in vals:
    case v.kind
    of vkWord:
      if v.wordKind == wkWord and v.wordName == "quit":
        for q in backend.quitCall():
          result.add(q)
      else:
        result.add(v)
    of vkBlock:
      result.add(ktgBlock(substituteQuit(v.blockVals, backend)))
    of vkParen:
      result.add(ktgParen(substituteQuit(v.parenVals, backend)))
    else:
      result.add(v)

proc substituteSelf*(vals: seq[KtgValue], entityName: string): seq[KtgValue] =
  result = newSeq[KtgValue](vals.len)
  for idx, v in vals:
    case v.kind
    of vkWord:
      if v.wordName == "self":
        raise newException(ValueError,
          "bare `self` is not valid; use `self/<field>`")
      elif v.wordName.startsWith("self/"):
        let suffix = v.wordName["self/".len .. ^1]
        result[idx] = ktgWord(entityName & "/" & suffix, v.wordKind)
      else:
        result[idx] = v
    of vkBlock:
      result[idx] = ktgBlock(substituteSelf(v.blockVals, entityName))
    of vkParen:
      result[idx] = ktgParen(substituteSelf(v.parenVals, entityName))
    else:
      result[idx] = v

proc assertNoSelf*(vals: seq[KtgValue], contextLabel: string) =
  for v in vals:
    case v.kind
    of vkWord:
      if v.wordName == "self" or v.wordName.startsWith("self/"):
        raise newException(ValueError,
          "`self` has no binding inside " & contextLabel)
    of vkBlock: assertNoSelf(v.blockVals, contextLabel)
    of vkParen: assertNoSelf(v.parenVals, contextLabel)
    else: discard

type
  Entity = object
    name: string
    ctxBlock: seq[KtgValue]
    updateBody: seq[KtgValue]

proc parseEntity(name: string, body: seq[KtgValue]): Entity =
  result.name = name
  var i = 0
  while i < body.len:
    let head = body[i]
    if head.kind == vkWord and head.wordKind == wkWord:
      case head.wordName
      of "pos":
        if i + 2 < body.len:
          result.ctxBlock.add(ktgWord("x", wkSetWord)); result.ctxBlock.add(body[i + 1])
          result.ctxBlock.add(ktgWord("y", wkSetWord)); result.ctxBlock.add(body[i + 2])
          i += 3
          continue
      of "rect":
        if i + 2 < body.len:
          result.ctxBlock.add(ktgWord("w", wkSetWord)); result.ctxBlock.add(body[i + 1])
          result.ctxBlock.add(ktgWord("h", wkSetWord)); result.ctxBlock.add(body[i + 2])
          i += 3
          continue
      of "color":
        if i + 3 < body.len:
          result.ctxBlock.add(ktgWord("cr", wkSetWord)); result.ctxBlock.add(body[i + 1])
          result.ctxBlock.add(ktgWord("cg", wkSetWord)); result.ctxBlock.add(body[i + 2])
          result.ctxBlock.add(ktgWord("cb", wkSetWord)); result.ctxBlock.add(body[i + 3])
          i += 4
          continue
      of "field":
        if i + 2 < body.len and body[i + 1].kind == vkWord and
           body[i + 1].wordKind == wkWord:
          result.ctxBlock.add(ktgWord(body[i + 1].wordName, wkSetWord))
          result.ctxBlock.add(body[i + 2])
          i += 3
          continue
      of "update":
        if i + 1 < body.len and body[i + 1].kind == vkBlock:
          for v in substituteSelf(body[i + 1].blockVals, name):
            result.updateBody.add(v)
          i += 2
          continue
      else:
        discard
    i += 1

proc expandScene(sceneName: string, sceneBody: seq[KtgValue],
                 backend: GameBackend): seq[KtgValue] =
  var stateBlock: seq[KtgValue] = @[]
  var entities: seq[Entity] = @[]
  var onKeys: seq[(KtgValue, seq[KtgValue])] = @[]

  var i = 0
  while i < sceneBody.len:
    let head = sceneBody[i]
    if head.kind == vkWord and head.wordKind == wkWord and head.wordName == "state" and
       i + 1 < sceneBody.len and sceneBody[i + 1].kind == vkBlock:
      for v in sceneBody[i + 1].blockVals:
        stateBlock.add(v)
      i += 2
    elif head.kind == vkWord and head.wordKind == wkWord and head.wordName == "entity" and
       i + 2 < sceneBody.len and sceneBody[i + 1].kind == vkWord and
       sceneBody[i + 1].wordKind == wkWord and sceneBody[i + 2].kind == vkBlock:
      let ent = parseEntity(sceneBody[i + 1].wordName, sceneBody[i + 2].blockVals)
      entities.add(ent)
      i += 3
    elif head.kind == vkWord and head.wordKind == wkWord and head.wordName == "on-key" and
         i + 2 < sceneBody.len and sceneBody[i + 1].kind == vkString and
         sceneBody[i + 2].kind == vkBlock:
      onKeys.add((sceneBody[i + 1], sceneBody[i + 2].blockVals))
      i += 3
    else:
      i += 1

  for v in stateBlock:
    result.add(v)
  for ent in entities:
    result.add(ktgWord(ent.name, wkSetWord))
    result.add(ktgWord("context", wkWord))
    result.add(ktgBlock(ent.ctxBlock))

  var updateStatements: seq[KtgValue] = @[]
  for ent in entities:
    for v in ent.updateBody:
      updateStatements.add(v)

  var drawStatements: seq[KtgValue] = @[]
  for ent in entities:
    let cr = ktgWord(ent.name & "/cr", wkWord)
    let cg = ktgWord(ent.name & "/cg", wkWord)
    let cb = ktgWord(ent.name & "/cb", wkWord)
    for v in backend.setColorCall(cr, cg, cb):
      drawStatements.add(v)
    let x = ktgWord(ent.name & "/x", wkWord)
    let y = ktgWord(ent.name & "/y", wkWord)
    let w = ktgWord(ent.name & "/w", wkWord)
    let h = ktgWord(ent.name & "/h", wkWord)
    for v in backend.drawRectCall(x, y, w, h):
      drawStatements.add(v)

  var keyBody: seq[KtgValue] = @[]
  if onKeys.len > 0:
    var matchArms: seq[KtgValue] = @[]
    for (keyStr, armBody) in onKeys:
      assertNoSelf(armBody, "on-key handler")
      matchArms.add(ktgBlock(@[keyStr]))
      matchArms.add(ktgBlock(substituteQuit(armBody, backend)))
    matchArms.add(ktgWord("default", wkWord))
    matchArms.add(ktgBlock(@[]))
    keyBody.add(ktgWord("match", wkWord))
    keyBody.add(ktgWord("key", wkWord))
    keyBody.add(ktgBlock(matchArms))

  for v in backend.loadShell(@[]): result.add(v)
  for v in backend.updateShell(updateStatements): result.add(v)
  for v in backend.drawShell(drawStatements): result.add(v)
  for v in backend.keypressedShell(keyBody): result.add(v)

proc expand*(blk: seq[KtgValue]): seq[KtgValue] =
  let targetName = findTarget(blk)
  if not backends.hasKey(targetName):
    raise newException(ValueError,
      "@game: unknown target '" & targetName & "'")
  let backend = backends[targetName]

  var consts: Table[string, KtgValue] = initTable[string, KtgValue]()
  var body: seq[KtgValue] = @[]

  var i = 0
  while i < blk.len:
    let v = blk[i]
    if v.kind == vkWord and v.wordKind == wkSetWord and v.wordName == "target":
      i += 2
    elif v.kind == vkWord and v.wordKind == wkWord and v.wordName == "constants" and
         i + 1 < blk.len and blk[i + 1].kind == vkBlock:
      for k, val in collectConstants(blk[i + 1].blockVals):
        consts[k] = val
      i += 2
    elif v.kind == vkWord and v.wordKind == wkWord and v.wordName == "scene" and
         i + 2 < blk.len and blk[i + 1].kind == vkWord and
         blk[i + 1].wordKind == wkLitWord and blk[i + 2].kind == vkBlock:
      for s in expandScene(blk[i + 1].wordName, blk[i + 2].blockVals, backend):
        body.add(s)
      i += 3
    elif v.kind == vkWord and v.wordKind == wkWord and v.wordName == "go":
      i += 2
    else:
      i += 1

  for v in backend.bindings:
    result.add(v)
  for v in inlineConstants(body, consts):
    result.add(v)
