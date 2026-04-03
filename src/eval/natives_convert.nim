import std/[strutils, math]
import ../core/types
import dialect

proc native(ctx: KtgContext, name: string, arity: int, fn: NativeFnProc) =
  ctx.set(name, KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: name, arity: arity, fn: fn),
    line: 0))

proc registerConvertNatives*(eval: Evaluator) =
  let ctx = eval.global

  ctx.native("to", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let target = if args[0].kind == vkType: args[0].typeName else: $args[0]
    let val = args[1]

    case target
    of "integer!":
      case val.kind
      of vkInteger: return val
      of vkFloat: return ktgInt(int64(val.floatVal))
      of vkString:
        try: return ktgInt(parseInt(val.strVal))
        except:
          try: return ktgInt(int64(parseFloat(val.strVal)))
          except: raise KtgError(kind: "type", msg: "cannot convert \"" & val.strVal & "\" to integer!", data: val)
      of vkMoney: return ktgInt(val.cents)
      of vkTime: return ktgInt(int64(val.hour) * 3600 + int64(val.minute) * 60 + int64(val.second))
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to integer!", data: val)

    of "float!":
      case val.kind
      of vkFloat: return val
      of vkInteger: return ktgFloat(float64(val.intVal))
      of vkString:
        try: return ktgFloat(parseFloat(val.strVal))
        except: raise KtgError(kind: "type", msg: "cannot convert \"" & val.strVal & "\" to float!", data: val)
      of vkMoney: return ktgFloat(float64(val.cents) / 100.0)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to float!", data: val)

    of "string!":
      if val.kind == vkWord:
        return ktgString(val.wordName)
      return ktgString($val)

    of "block!":
      case val.kind
      of vkBlock: return val
      of vkPair: return ktgBlock(@[ktgInt(int64(val.px)), ktgInt(int64(val.py))])
      of vkTuple:
        var vals: seq[KtgValue] = @[]
        for v in val.tupleVals: vals.add(ktgInt(int64(v)))
        return ktgBlock(vals)
      else: return ktgBlock(@[val])

    of "money!":
      case val.kind
      of vkMoney: return val
      of vkInteger: return ktgMoney(val.intVal * 100)
      of vkFloat: return ktgMoney(int64(round(val.floatVal * 100.0)))
      of vkString:
        try:
          let f = parseFloat(val.strVal)
          return ktgMoney(int64(round(f * 100.0)))
        except: raise KtgError(kind: "type", msg: "cannot convert to money!", data: val)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to money!", data: val)

    of "pair!":
      if val.kind == vkBlock and val.blockVals.len == 2:
        let x = if val.blockVals[0].kind == vkInteger: int32(val.blockVals[0].intVal) else: 0'i32
        let y = if val.blockVals[1].kind == vkInteger: int32(val.blockVals[1].intVal) else: 0'i32
        return ktgPair(x, y)
      if val.kind == vkString:
        let parts = val.strVal.split('x')
        if parts.len == 2:
          return ktgPair(int32(parseInt(parts[0])), int32(parseInt(parts[1])))
      raise KtgError(kind: "type", msg: "cannot convert to pair!", data: val)

    of "word!":
      if val.kind == vkString: return ktgWord(val.strVal, wkWord)
      if val.kind == vkWord: return ktgWord(val.wordName, wkWord)
      raise KtgError(kind: "type", msg: "cannot convert to word!", data: val)

    of "set-word!":
      if val.kind == vkString: return ktgWord(val.strVal, wkSetWord)
      if val.kind == vkWord: return ktgWord(val.wordName, wkSetWord)
      raise KtgError(kind: "type", msg: "cannot convert to set-word!", data: val)

    of "lit-word!":
      if val.kind == vkString: return ktgWord(val.strVal, wkLitWord)
      if val.kind == vkWord: return ktgWord(val.wordName, wkLitWord)
      raise KtgError(kind: "type", msg: "cannot convert to lit-word!", data: val)

    of "get-word!":
      if val.kind == vkString: return ktgWord(val.strVal, wkGetWord)
      if val.kind == vkWord: return ktgWord(val.wordName, wkGetWord)
      raise KtgError(kind: "type", msg: "cannot convert to get-word!", data: val)

    of "meta-word!":
      if val.kind == vkString: return ktgWord(val.strVal, wkMetaWord)
      if val.kind == vkWord: return ktgWord(val.wordName, wkMetaWord)
      raise KtgError(kind: "type", msg: "cannot convert to meta-word!", data: val)

    of "logic!":
      if val.kind == vkLogic: return val
      if val.kind == vkNone: return ktgLogic(false)
      if val.kind == vkString:
        if val.strVal == "true": return ktgLogic(true)
        if val.strVal == "false": return ktgLogic(false)
      raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to logic!", data: val)

    of "time!":
      case val.kind
      of vkTime: return val
      of vkInteger:
        let total = val.intVal
        let h = uint8((total div 3600) mod 24)
        let m = uint8((total mod 3600) div 60)
        let s = uint8(total mod 60)
        return KtgValue(kind: vkTime, hour: h, minute: m, second: s, line: 0)
      of vkString:
        let parts = val.strVal.split(':')
        if parts.len >= 2:
          let h = uint8(parseInt(parts[0]))
          let m = uint8(parseInt(parts[1]))
          let s = if parts.len >= 3: uint8(parseInt(parts[2])) else: 0'u8
          return KtgValue(kind: vkTime, hour: h, minute: m, second: s, line: 0)
        raise KtgError(kind: "type", msg: "cannot convert \"" & val.strVal & "\" to time!", data: val)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to time!", data: val)

    of "date!":
      case val.kind
      of vkDate: return val
      of vkString:
        let parts = val.strVal.split('-')
        if parts.len == 3:
          return KtgValue(kind: vkDate,
            year: int16(parseInt(parts[0])),
            month: uint8(parseInt(parts[1])),
            day: uint8(parseInt(parts[2])),
            line: 0)
        raise KtgError(kind: "type", msg: "cannot convert \"" & val.strVal & "\" to date!", data: val)
      of vkBlock:
        if val.blockVals.len == 3:
          let y = if val.blockVals[0].kind == vkInteger: int16(val.blockVals[0].intVal) else: 0'i16
          let m = if val.blockVals[1].kind == vkInteger: uint8(val.blockVals[1].intVal) else: 0'u8
          let d = if val.blockVals[2].kind == vkInteger: uint8(val.blockVals[2].intVal) else: 0'u8
          return KtgValue(kind: vkDate, year: y, month: m, day: d, line: 0)
        raise KtgError(kind: "type", msg: "cannot convert block to date! (need 3 elements)", data: val)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to date!", data: val)

    of "tuple!":
      case val.kind
      of vkTuple: return val
      of vkBlock:
        var vals: seq[uint8] = @[]
        for v in val.blockVals:
          if v.kind == vkInteger: vals.add(uint8(v.intVal))
          else: raise KtgError(kind: "type", msg: "tuple elements must be integers 0-255", data: v)
        return KtgValue(kind: vkTuple, tupleVals: vals, line: 0)
      of vkString:
        var vals: seq[uint8] = @[]
        for part in val.strVal.split('.'):
          vals.add(uint8(parseInt(part)))
        return KtgValue(kind: vkTuple, tupleVals: vals, line: 0)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to tuple!", data: val)

    of "file!":
      case val.kind
      of vkFile: return val
      of vkString: return ktgFile(val.strVal)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to file!", data: val)

    of "url!":
      case val.kind
      of vkUrl: return val
      of vkString: return ktgUrl(val.strVal)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to url!", data: val)

    of "email!":
      case val.kind
      of vkEmail: return val
      of vkString: return ktgEmail(val.strVal)
      else: raise KtgError(kind: "type", msg: "cannot convert " & typeName(val) & " to email!", data: val)

    else:
      raise KtgError(kind: "type", msg: "unknown target type: " & target, data: nil)
  )
