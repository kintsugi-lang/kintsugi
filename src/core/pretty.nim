import std/strutils
import types

proc prettyPrintValue*(v: KtgValue): string
proc prettyPrintBlock*(vals: seq[KtgValue]): string

proc escapeString(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"':  result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\t': result.add("\\t")
    of '\r': result.add("\\r")
    else:    result.add(c)
  result.add("\"")

proc prettyPrintValue*(v: KtgValue): string =
  case v.kind
  of vkInteger: $v.intVal
  of vkFloat:   $v.floatVal
  of vkString:  escapeString(v.strVal)
  of vkLogic:   (if v.boolVal: "true" else: "false")
  of vkNone:    "none"
  of vkMoney:
    let negative = v.cents < 0
    let absCents = abs(v.cents)
    let dollars = absCents div 100
    let cents = absCents mod 100
    (if negative: "-" else: "") & "$" & $dollars & "." &
      (if cents < 10: "0" & $cents else: $cents)
  of vkPair:  $v.px & "x" & $v.py
  of vkTuple:
    var parts: seq[string] = @[]
    for b in v.tupleVals: parts.add($b)
    parts.join(".")
  of vkDate:
    $v.year & "-" &
      (if v.month < 10: "0" else: "") & $v.month & "-" &
      (if v.day   < 10: "0" else: "") & $v.day
  of vkTime:
    (if v.hour   < 10: "0" else: "") & $v.hour   & ":" &
    (if v.minute < 10: "0" else: "") & $v.minute & ":" &
    (if v.second < 10: "0" else: "") & $v.second
  of vkFile:  "%" & v.filePath
  of vkUrl:   v.urlVal
  of vkEmail: v.emailVal
  of vkBlock: "[" & prettyPrintBlock(v.blockVals) & "]"
  of vkParen: "(" & prettyPrintBlock(v.parenVals) & ")"
  of vkWord:
    case v.wordKind
    of wkWord:     v.wordName
    of wkSetWord:  v.wordName & ":"
    of wkGetWord:  ":" & v.wordName
    of wkLitWord:  "'" & v.wordName
    of wkMetaWord: "@" & v.wordName
  of vkOp:   v.opSymbol
  of vkType: v.typeName
  else:
    raise newException(ValueError,
      "prettyPrintValue: unsupported value kind " & $v.kind &
      " (pretty printer is for preprocess-time AST only)")

proc prettyPrintBlock*(vals: seq[KtgValue]): string =
  var parts: seq[string] = @[]
  for v in vals:
    parts.add(prettyPrintValue(v))
  parts.join(" ")
