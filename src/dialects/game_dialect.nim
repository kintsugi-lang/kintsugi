import std/[tables, strutils]
import ../core/types
import game_backend
export game_backend
import game_playdate

proc love2dEmitCallbacks(updateBody, drawBody: seq[KtgValue]): seq[KtgValue] =
  result.add(ktgWord("love/load", wkSetWord))
  result.add(ktgWord("function", wkWord))
  result.add(ktgBlock(@[]))
  result.add(ktgBlock(@[]))

  result.add(ktgWord("love/update", wkSetWord))
  result.add(ktgWord("function", wkWord))
  result.add(ktgBlock(@[ktgWord("dt", wkWord)]))
  result.add(ktgBlock(updateBody))

  result.add(ktgWord("love/draw", wkSetWord))
  result.add(ktgWord("function", wkWord))
  result.add(ktgBlock(@[]))
  result.add(ktgBlock(drawBody))

proc love2dBindings(): seq[KtgValue] =
  var entries: seq[KtgValue]
  for v in bindingEntry("love/graphics/setColor",  "love.graphics.setColor",  "call", 4): entries.add(v)
  for v in bindingEntry("love/graphics/rectangle", "love.graphics.rectangle", "call", 5): entries.add(v)
  for v in bindingEntry("love/event/quit",          "love.event.quit",          "call", 0): entries.add(v)
  for v in bindingEntry("love/keyboard/isDown",     "love.keyboard.isDown",     "call", 1): entries.add(v)
  for v in bindingEntry("love/graphics/print",      "love.graphics.print",      "call", 3): entries.add(v)
  for v in bindingEntry("love/load",       "love.load",       "assign"): entries.add(v)
  for v in bindingEntry("love/update",     "love.update",     "assign"): entries.add(v)
  for v in bindingEntry("love/draw",       "love.draw",       "assign"): entries.add(v)
  for v in bindingEntry("love/keypressed", "love.keypressed", "assign"): entries.add(v)
  @[ktgWord("bindings", wkWord), ktgBlock(entries)]

proc love2dDrawEntity(name: string): seq[KtgValue] =
  ## Emits: love.graphics.setColor(n.cr, n.cg, n.cb, 1)
  ##        love.graphics.rectangle("fill", n.x, n.y, n.w, n.h)
  @[
    ktgWord("love/graphics/setColor", wkWord),
    ktgWord(name & "/cr", wkWord),
    ktgWord(name & "/cg", wkWord),
    ktgWord(name & "/cb", wkWord),
    ktgInt(1),
    ktgWord("love/graphics/rectangle", wkWord),
    ktgWord("fill", wkLitWord),
    ktgWord(name & "/x", wkWord),
    ktgWord(name & "/y", wkWord),
    ktgWord(name & "/w", wkWord),
    ktgWord(name & "/h", wkWord),
  ]

let love2dBackend* = GameBackend(
  name: "love2d",
  bindings: love2dBindings(),
  storesColor: true,
  emitCallbacks: love2dEmitCallbacks,
  drawEntity: love2dDrawEntity,
)

var backends* = {
  "love2d": love2dBackend,
  "playdate": playdateBackend,
}.toTable


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

proc substituteIt*(vals: seq[KtgValue], otherName: string): seq[KtgValue] =
  result = newSeq[KtgValue](vals.len)
  for idx, v in vals:
    case v.kind
    of vkWord:
      if v.wordName == "it":
        raise newException(ValueError,
          "bare `it` is not valid; use `it/<field>`")
      elif v.wordName.startsWith("it/"):
        let suffix = v.wordName["it/".len .. ^1]
        let newName = otherName & "/" & suffix
        result[idx] = ktgWord(newName, v.wordKind)
      else:
        result[idx] = v
    of vkBlock:
      result[idx] = ktgBlock(substituteIt(v.blockVals, otherName))
    of vkParen:
      result[idx] = ktgParen(substituteIt(v.parenVals, otherName))
    else:
      result[idx] = v

proc assertNoIt*(vals: seq[KtgValue], contextLabel: string) =
  for v in vals:
    case v.kind
    of vkWord:
      if v.wordName == "it" or v.wordName.startsWith("it/"):
        raise newException(ValueError,
          "`it` has no binding inside " & contextLabel)
    of vkBlock: assertNoIt(v.blockVals, contextLabel)
    of vkParen: assertNoIt(v.parenVals, contextLabel)
    else: discard

type
  Entity = object
    name: string
    ctxBlock: seq[KtgValue]
    updateBody: seq[KtgValue]
    drawBody: seq[KtgValue]      ## non-empty = custom draw; empty = auto-rect
    hasCustomDraw: bool
    tags: seq[string]

  CollideForm = object
    selfEntity: string
    tagOrEntity: string
    isTag: bool
    body: seq[KtgValue]

proc takeTwoNums(body: seq[KtgValue], i: int): (KtgValue, KtgValue, int) =
  ## Two-number dialect args accept either two scalars or a single pair literal.
  if i + 1 < body.len and body[i + 1].kind == vkPair:
    let p = body[i + 1]
    return (ktgInt(p.px.int64), ktgInt(p.py.int64), 2)
  if i + 2 < body.len:
    return (body[i + 1], body[i + 2], 3)
  return (nil, nil, 0)

proc parseEntity(name: string, body: seq[KtgValue],
                 storesColor: bool = true): Entity =
  result.name = name
  var i = 0
  while i < body.len:
    let head = body[i]
    if head.kind == vkWord and head.wordKind == wkWord:
      case head.wordName
      of "pos":
        let (a, b, step) = takeTwoNums(body, i)
        if step > 0:
          result.ctxBlock.add(ktgWord("x", wkSetWord)); result.ctxBlock.add(a)
          result.ctxBlock.add(ktgWord("y", wkSetWord)); result.ctxBlock.add(b)
          i += step
          continue
      of "rect":
        let (a, b, step) = takeTwoNums(body, i)
        if step > 0:
          result.ctxBlock.add(ktgWord("w", wkSetWord)); result.ctxBlock.add(a)
          result.ctxBlock.add(ktgWord("h", wkSetWord)); result.ctxBlock.add(b)
          i += step
          continue
      of "color":
        if i + 3 < body.len:
          if storesColor:
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
      of "draw":
        if i + 1 < body.len and body[i + 1].kind == vkBlock:
          for v in substituteSelf(body[i + 1].blockVals, name):
            result.drawBody.add(v)
          result.hasCustomDraw = true
          i += 2
          continue
      of "tags":
        if i + 1 < body.len and body[i + 1].kind == vkBlock:
          for t in body[i + 1].blockVals:
            if t.kind == vkWord and t.wordKind == wkWord:
              result.tags.add(t.wordName)
          i += 2
          continue
      else:
        discard
    i += 1

proc collectTagMap*(gameBlock: seq[KtgValue]): Table[string, seq[string]] =
  result = initTable[string, seq[string]]()
  var i = 0
  while i < gameBlock.len:
    let v = gameBlock[i]
    if v.kind == vkWord and v.wordKind == wkWord and v.wordName == "scene" and
       i + 2 < gameBlock.len and gameBlock[i + 2].kind == vkBlock:
      let sceneBody = gameBlock[i + 2].blockVals
      var j = 0
      while j < sceneBody.len:
        let h = sceneBody[j]
        if h.kind == vkWord and h.wordKind == wkWord and h.wordName == "entity" and
           j + 2 < sceneBody.len and sceneBody[j + 1].kind == vkWord and
           sceneBody[j + 2].kind == vkBlock:
          let ent = parseEntity(sceneBody[j + 1].wordName, sceneBody[j + 2].blockVals)
          for tag in ent.tags:
            if not result.hasKey(tag):
              result[tag] = @[]
            result[tag].add(ent.name)
          j += 3
        else:
          j += 1
      break
    i += 1

proc expandScene(sceneName: string, sceneBody: seq[KtgValue],
                 backend: GameBackend): seq[KtgValue] =
  var stateBlock: seq[KtgValue] = @[]
  var entities: seq[Entity] = @[]
  var collides: seq[CollideForm] = @[]
  var userDrawBody: seq[KtgValue] = @[]
  var userUpdatePre: seq[KtgValue] = @[]

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
      let ent = parseEntity(sceneBody[i + 1].wordName, sceneBody[i + 2].blockVals,
                            backend.storesColor)
      entities.add(ent)
      i += 3
    elif head.kind == vkWord and head.wordKind == wkWord and head.wordName == "collide" and
         i + 3 < sceneBody.len and sceneBody[i + 1].kind == vkWord and
         sceneBody[i + 1].wordKind == wkWord and
         sceneBody[i + 2].kind == vkWord and
         (sceneBody[i + 2].wordKind == wkLitWord or sceneBody[i + 2].wordKind == wkWord) and
         sceneBody[i + 3].kind == vkBlock:
      collides.add(CollideForm(
        selfEntity: sceneBody[i + 1].wordName,
        tagOrEntity: sceneBody[i + 2].wordName,
        isTag: sceneBody[i + 2].wordKind == wkLitWord,
        body: sceneBody[i + 3].blockVals,
      ))
      i += 4
    elif head.kind == vkWord and head.wordKind == wkWord and head.wordName == "draw" and
         i + 1 < sceneBody.len and sceneBody[i + 1].kind == vkBlock:
      assertNoSelf(sceneBody[i + 1].blockVals, "scene draw block")
      for v in sceneBody[i + 1].blockVals:
        userDrawBody.add(v)
      i += 2
    elif head.kind == vkWord and head.wordKind == wkWord and head.wordName == "on-update" and
         i + 1 < sceneBody.len and sceneBody[i + 1].kind == vkBlock:
      assertNoSelf(sceneBody[i + 1].blockVals, "scene on-update block")
      for v in sceneBody[i + 1].blockVals:
        userUpdatePre.add(v)
      i += 2
    else:
      i += 1

  for v in stateBlock:
    result.add(v)
  for ent in entities:
    result.add(ktgWord(ent.name, wkSetWord))
    result.add(ktgWord("context", wkWord))
    result.add(ktgBlock(ent.ctxBlock))

  var tagMap: Table[string, seq[string]] = initTable[string, seq[string]]()
  for ent in entities:
    for tag in ent.tags:
      if not tagMap.hasKey(tag):
        tagMap[tag] = @[]
      tagMap[tag].add(ent.name)

  var updateStatements: seq[KtgValue] = @[]
  for v in backend.framePrelude:
    updateStatements.add(v)
  for v in userUpdatePre:
    updateStatements.add(v)
  for ent in entities:
    for v in ent.updateBody:
      updateStatements.add(v)

  for coll in collides:
    let others =
      if coll.isTag:
        if tagMap.hasKey(coll.tagOrEntity): tagMap[coll.tagOrEntity] else: @[]
      else:
        @[coll.tagOrEntity]
    for other in others:
      if other == coll.selfEntity: continue
      let s = coll.selfEntity
      let o = other
      let aabbBlock = ktgBlock(@[
        ktgWord(s & "/x", wkWord), KtgValue(kind: vkOp, opFn: nil, opSymbol: "<"),
        ktgParen(@[ktgWord(o & "/x", wkWord), KtgValue(kind: vkOp, opFn: nil, opSymbol: "+"), ktgWord(o & "/w", wkWord)]),
        ktgWord(o & "/x", wkWord), KtgValue(kind: vkOp, opFn: nil, opSymbol: "<"),
        ktgParen(@[ktgWord(s & "/x", wkWord), KtgValue(kind: vkOp, opFn: nil, opSymbol: "+"), ktgWord(s & "/w", wkWord)]),
        ktgWord(s & "/y", wkWord), KtgValue(kind: vkOp, opFn: nil, opSymbol: "<"),
        ktgParen(@[ktgWord(o & "/y", wkWord), KtgValue(kind: vkOp, opFn: nil, opSymbol: "+"), ktgWord(o & "/h", wkWord)]),
        ktgWord(o & "/y", wkWord), KtgValue(kind: vkOp, opFn: nil, opSymbol: "<"),
        ktgParen(@[ktgWord(s & "/y", wkWord), KtgValue(kind: vkOp, opFn: nil, opSymbol: "+"), ktgWord(s & "/h", wkWord)]),
      ])
      updateStatements.add(ktgWord("if", wkWord))
      updateStatements.add(ktgWord("all?", wkWord))
      updateStatements.add(aabbBlock)
      updateStatements.add(ktgBlock(substituteIt(coll.body, o)))

  var drawStatements: seq[KtgValue] = @[]
  for ent in entities:
    if ent.hasCustomDraw:
      ## User-supplied draw block for this entity - already self/-substituted.
      for v in ent.drawBody:
        drawStatements.add(v)
    else:
      ## Target-optimal auto-rect for this entity.
      for v in backend.drawEntity(ent.name):
        drawStatements.add(v)
  for v in userDrawBody:
    drawStatements.add(v)

  for v in backend.emitCallbacks(updateStatements, drawStatements):
    result.add(v)

proc expand*(blk: seq[KtgValue], targetName: string): seq[KtgValue] =
  if targetName.len == 0:
    raise newException(ValueError,
      "@game requires a compile target; pass --target=<name> " &
      "(available: love2d, playdate). @game cannot be used in the REPL " &
      "or interpret mode.")
  if not backends.hasKey(targetName):
    raise newException(ValueError,
      "@game: unknown target '" & targetName & "'")
  let backend = backends[targetName]

  var consts: Table[string, KtgValue] = initTable[string, KtgValue]()
  var body: seq[KtgValue] = @[]
  var userBindings: seq[KtgValue] = @[]

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
    elif v.kind == vkWord and v.wordKind == wkWord and v.wordName == "bindings" and
         i + 1 < blk.len and blk[i + 1].kind == vkBlock:
      for entry in blk[i + 1].blockVals:
        userBindings.add(entry)
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

  if userBindings.len > 0:
    ## Splice user entries into the backend's bindings block (second element).
    if backend.bindings.len >= 2 and backend.bindings[1].kind == vkBlock:
      var mergedEntries: seq[KtgValue] = @[]
      for e in backend.bindings[1].blockVals:
        mergedEntries.add(e)
      for e in userBindings:
        mergedEntries.add(e)
      result.add(backend.bindings[0])
      result.add(ktgBlock(mergedEntries))
    else:
      for v in backend.bindings:
        result.add(v)
      result.add(ktgWord("bindings", wkWord))
      result.add(ktgBlock(userBindings))
  else:
    for v in backend.bindings:
      result.add(v)

  for v in backend.prelude:
    result.add(v)

  for v in inlineConstants(body, consts):
    result.add(v)
