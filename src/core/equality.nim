import std/[tables, sets, unicode]
import types

proc valuesEqual*(a, b: KtgValue): bool =
  ## ONE equality function. 10 rules from spec section 5.
  ## Rule 10: cross-type comparisons are false (unless a rule above applies).

  if a.isNil and b.isNil: return true
  if a.isNil or b.isNil: return false

  # Rule 9: none equals only none
  if a.kind == vkNone and b.kind == vkNone: return true
  if a.kind == vkNone or b.kind == vkNone: return false

  # Rule 1: numeric equality is cross-type (integer and float)
  if a.kind in {vkInteger, vkFloat} and b.kind in {vkInteger, vkFloat}:
    let av = if a.kind == vkInteger: float64(a.intVal) else: a.floatVal
    let bv = if b.kind == vkInteger: float64(b.intVal) else: b.floatVal
    return av == bv

  # Rule 2: money is its own domain (only money = money)
  if a.kind == vkMoney and b.kind == vkMoney:
    return a.cents == b.cents

  # Rule 10: different types from here on → false
  if a.kind != b.kind: return false

  # Same type from here on
  case a.kind
  # Rule 6: strings are case-sensitive
  of vkString: return a.strVal == b.strVal

  of vkLogic: return a.boolVal == b.boolVal
  of vkInteger: return a.intVal == b.intVal
  of vkFloat: return a.floatVal == b.floatVal

  # Rule 3: value types compare structurally, deep recursive
  of vkPair: return a.px == b.px and a.py == b.py
  of vkTuple: return a.tupleVals == b.tupleVals
  of vkDate: return a.year == b.year and a.month == b.month and a.day == b.day
  of vkTime: return a.hour == b.hour and a.minute == b.minute and a.second == b.second
  of vkFile: return a.filePath == b.filePath
  of vkUrl: return a.urlVal == b.urlVal
  of vkEmail: return a.emailVal == b.emailVal

  # Rule 3: blocks compare deep recursive
  of vkBlock:
    if a.blockVals.len != b.blockVals.len: return false
    for i in 0 ..< a.blockVals.len:
      if not valuesEqual(a.blockVals[i], b.blockVals[i]): return false
    return true

  of vkParen:
    if a.parenVals.len != b.parenVals.len: return false
    for i in 0 ..< a.parenVals.len:
      if not valuesEqual(a.parenVals[i], b.parenVals[i]): return false
    return true

  # Rule 4: maps compare structurally, order-independent
  of vkMap:
    if a.mapEntries.len != b.mapEntries.len: return false
    for key, aVal in a.mapEntries:
      if key notin b.mapEntries: return false
      if not valuesEqual(aVal, b.mapEntries[key]): return false
    return true

  # Rule 5: contexts compare structurally
  of vkContext:
    if a.ctx.entries.len != b.ctx.entries.len: return false
    for key, aVal in a.ctx.entries:
      if key notin b.ctx.entries: return false
      if not valuesEqual(aVal, b.ctx.entries[key]): return false
    return true

  of vkPrototype:
    if a.proto.entries.len != b.proto.entries.len: return false
    for key, aVal in a.proto.entries:
      if key notin b.proto.entries: return false
      if not valuesEqual(aVal, b.proto.entries[key]): return false
    return true

  of vkSet:
    return a.setMembers == b.setMembers

  # Rule 7: words — same subtype, case-insensitive
  of vkWord:
    if a.wordKind != b.wordKind: return false
    return toLower(a.wordName) == toLower(b.wordName)

  of vkType:
    return a.typeName == b.typeName

  # Rule 8: functions compare by identity
  of vkFunction: return a.fn == b.fn
  of vkNative: return a.nativeFn == b.nativeFn
  of vkOp: return a.opFn == b.opFn

  of vkMoney: return a.cents == b.cents
  of vkNone: return true  # handled above, but exhaustive
