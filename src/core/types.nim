import std/[tables, sets, hashes, strutils]

type
  WordKind* = enum
    wkWord      ## word    — evaluate / lookup
    wkSetWord   ## word:   — bind a value
    wkGetWord   ## :word   — get without calling
    wkLitWord   ## 'word   — the symbol itself
    wkMetaWord  ## @word   — lifecycle hooks / metadata

  ValueKind* = enum
    vkInteger
    vkFloat
    vkString
    vkLogic
    vkNone
    vkMoney     ## cents-based integer, no float drift
    vkPair      ## 2D coordinates: 100x200
    vkTuple     ## version/color: 1.2.3
    vkDate
    vkTime
    vkFile      ## %path/to/file
    vkUrl       ## https://...
    vkEmail     ## user@domain
    vkBlock     ## [...] — inert data
    vkParen     ## (...) — evaluates immediately
    vkMap       ## key-value store
    vkSet       ## unordered unique collection, O(1) membership
    vkContext   ## mutable scope/instance
    vkPrototype ## frozen prototype/module
    vkFunction  ## user-defined function
    vkNative    ## built-in function
    vkOp        ## infix operator
    vkType      ## type name value
    vkWord      ## all word subtypes

  CustomType* = ref object
    rule*: seq[KtgValue]       ## the type rule block (e.g., [string! | none!])
    guard*: seq[KtgValue]      ## where clause body (empty if none)
    isEnum*: bool              ## true if @type/enum
    isStruct*: bool            ## true if structural type (field validation)

  KtgValue* = ref object
    line*: int              ## source line for error reporting
    boundCtx*: KtgContext   ## context for bind/do — nil means use current
    customType*: CustomType ## non-nil if this value represents a custom type
    case kind*: ValueKind
    of vkInteger:   intVal*: int64
    of vkFloat:     floatVal*: float64
    of vkString:    strVal*: string
    of vkLogic:     boolVal*: bool
    of vkNone:      discard
    of vkMoney:     cents*: int64
    of vkPair:      px*, py*: int32
    of vkTuple:     tupleVals*: seq[uint8]
    of vkDate:
      year*: int16
      month*, day*: uint8
    of vkTime:
      hour*, minute*, second*: uint8
    of vkFile:      filePath*: string
    of vkUrl:       urlVal*: string
    of vkEmail:     emailVal*: string
    of vkBlock:     blockVals*: seq[KtgValue]
    of vkParen:     parenVals*: seq[KtgValue]
    of vkMap:       mapEntries*: OrderedTable[string, KtgValue]
    of vkSet:       setMembers*: HashSet[string]
    of vkContext:   ctx*: KtgContext
    of vkPrototype: proto*: KtgPrototype
    of vkFunction:  fn*: KtgFunc
    of vkNative:    nativeFn*: KtgNative
    of vkOp:
      opFn*: KtgNative
      opSymbol*: string
    of vkType:      typeName*: string
    of vkWord:
      wordName*: string
      wordKind*: WordKind

  KtgContext* = ref object
    entries*: OrderedTable[string, KtgValue]
    parent*: KtgContext

  FieldSpec* = object
    name*: string
    typeName*: string   ## "" = untyped
    hasDefault*: bool
    defaultVal*: KtgValue

  KtgPrototype* = ref object
    entries*: OrderedTable[string, KtgValue]
    fieldSpecs*: seq[FieldSpec]
    name*: string       ## prototype name for auto-gen

  ParamSpec* = object
    name*: string
    typeName*: string   ## "" = untyped
    elementType*: string ## for typed blocks: [block! integer!] -> "integer!"
    isOpt*: bool        ## [opt type!]

  RefinementSpec* = object
    name*: string
    params*: seq[ParamSpec]

  ParsedFuncSpec* = object
    params*: seq[ParamSpec]
    refinements*: seq[RefinementSpec]
    returnType*: string

  KtgFunc* = ref object
    params*: seq[ParamSpec]
    refinements*: seq[RefinementSpec]
    returnType*: string   ## "" = untyped
    body*: seq[KtgValue]
    closure*: KtgContext  ## captured scope

  NativeFnProc* = proc(args: seq[KtgValue], eval: pointer): KtgValue

  KtgNative* = ref object
    name*: string
    arity*: int
    fn*: NativeFnProc
    refinements*: seq[RefinementSpec]

  StackFrame* = object
    name*: string
    file*: string
    line*: int

  KtgError* = ref object of CatchableError
    kind*: string         ## 'type, 'math, 'undefined, etc.
    data*: KtgValue
    stack*: seq[StackFrame]


# --- Value constructors ---

proc ktgInt*(v: int64, line = 0): KtgValue =
  KtgValue(kind: vkInteger, intVal: v, line: line)

proc ktgFloat*(v: float64, line = 0): KtgValue =
  KtgValue(kind: vkFloat, floatVal: v, line: line)

proc ktgString*(v: string, line = 0): KtgValue =
  KtgValue(kind: vkString, strVal: v, line: line)

proc ktgLogic*(v: bool, line = 0): KtgValue =
  KtgValue(kind: vkLogic, boolVal: v, line: line)

proc ktgNone*(line = 0): KtgValue =
  KtgValue(kind: vkNone, line: line)

proc ktgMoney*(cents: int64, line = 0): KtgValue =
  KtgValue(kind: vkMoney, cents: cents, line: line)

proc ktgPair*(x, y: int32, line = 0): KtgValue =
  KtgValue(kind: vkPair, px: x, py: y, line: line)

proc ktgBlock*(vals: seq[KtgValue] = @[], line = 0): KtgValue =
  KtgValue(kind: vkBlock, blockVals: vals, line: line)

proc ktgParen*(vals: seq[KtgValue] = @[], line = 0): KtgValue =
  KtgValue(kind: vkParen, parenVals: vals, line: line)

proc ktgWord*(name: string, wk: WordKind, line = 0): KtgValue =
  KtgValue(kind: vkWord, wordName: name, wordKind: wk, line: line)

proc ktgType*(name: string, line = 0): KtgValue =
  KtgValue(kind: vkType, typeName: name, line: line)

proc ktgFile*(path: string, line = 0): KtgValue =
  KtgValue(kind: vkFile, filePath: path, line: line)

proc ktgUrl*(url: string, line = 0): KtgValue =
  KtgValue(kind: vkUrl, urlVal: url, line: line)

proc ktgEmail*(email: string, line = 0): KtgValue =
  KtgValue(kind: vkEmail, emailVal: email, line: line)


# --- Context operations ---

proc newContext*(parent: KtgContext = nil): KtgContext =
  KtgContext(entries: initOrderedTable[string, KtgValue](), parent: parent)

proc get*(ctx: KtgContext, name: string): KtgValue =
  var c = ctx
  while c != nil:
    if name in c.entries:
      return c.entries[name]
    c = c.parent
  raise KtgError(
    kind: "undefined",
    msg: name & " has no value",
    data: ktgWord(name, wkWord)
  )

proc set*(ctx: KtgContext, name: string, val: KtgValue) =
  ## Always sets in current scope (shadowing).
  ctx.entries[name] = val

proc setThrough*(ctx: KtgContext, name: string, val: KtgValue) =
  ## Write-through: if name exists in a parent scope, write there.
  ## If not, create in current scope (new local).
  var c = ctx.parent
  while c != nil:
    if name in c.entries:
      c.entries[name] = val
      return
    c = c.parent
  # Not found in any parent — create local
  ctx.entries[name] = val

proc has*(ctx: KtgContext, name: string): bool =
  var c = ctx
  while c != nil:
    if name in c.entries:
      return true
    c = c.parent
  false

proc child*(ctx: KtgContext): KtgContext =
  newContext(parent = ctx)


# --- Prototype operations ---

proc newPrototype*(entries: OrderedTable[string, KtgValue],
                   fieldSpecs: seq[FieldSpec] = @[],
                   name: string = ""): KtgPrototype =
  KtgPrototype(entries: entries, fieldSpecs: fieldSpecs, name: name)

proc get*(proto: KtgPrototype, name: string): KtgValue =
  if name in proto.entries:
    return proto.entries[name]
  raise KtgError(
    kind: "undefined",
    msg: name & " not found on prototype",
    data: ktgWord(name, wkWord)
  )

proc has*(proto: KtgPrototype, name: string): bool =
  name in proto.entries



# --- Truthiness ---

proc isTruthy*(val: KtgValue): bool =
  ## Only false and none are falsy. Everything else is truthy.
  case val.kind
  of vkLogic: val.boolVal
  of vkNone: false
  else: true


# --- Type name ---

proc typeName*(val: KtgValue): string =
  case val.kind
  of vkInteger:  "integer!"
  of vkFloat:    "float!"
  of vkString:   "string!"
  of vkLogic:    "logic!"
  of vkNone:     "none!"
  of vkMoney:    "money!"
  of vkPair:     "pair!"
  of vkTuple:    "tuple!"
  of vkDate:     "date!"
  of vkTime:     "time!"
  of vkFile:     "file!"
  of vkUrl:      "url!"
  of vkEmail:    "email!"
  of vkBlock:    "block!"
  of vkParen:    "paren!"
  of vkMap:      "map!"
  of vkSet:      "set!"
  of vkContext:  "context!"
  of vkPrototype: "prototype!"
  of vkFunction: "function!"
  of vkNative:   "native!"
  of vkOp:       "op!"
  of vkType:     "type!"
  of vkWord:
    case val.wordKind
    of wkWord:     "word!"
    of wkSetWord:  "set-word!"
    of wkGetWord:  "get-word!"
    of wkLitWord:  "lit-word!"
    of wkMetaWord: "meta-word!"


# --- Display ---

proc `$`*(val: KtgValue): string =
  case val.kind
  of vkInteger:  $val.intVal
  of vkFloat:    $val.floatVal
  of vkString:   val.strVal
  of vkLogic:
    if val.boolVal: "true" else: "false"
  of vkNone:     "none"
  of vkMoney:
    let negative = val.cents < 0
    let absCents = abs(val.cents)
    let dollars = absCents div 100
    let cents = absCents mod 100
    (if negative: "-" else: "") & "$" & $dollars & "." & (if cents < 10: "0" & $cents else: $cents)
  of vkPair:     $val.px & "x" & $val.py
  of vkTuple:
    var s = ""
    for i, v in val.tupleVals:
      if i > 0: s &= "."
      s &= $v
    s
  of vkDate:
    $val.year & "-" &
      (if val.month < 10: "0" else: "") & $val.month & "-" &
      (if val.day < 10: "0" else: "") & $val.day
  of vkTime:
    (if val.hour < 10: "0" else: "") & $val.hour & ":" &
      (if val.minute < 10: "0" else: "") & $val.minute & ":" &
      (if val.second < 10: "0" else: "") & $val.second
  of vkFile:     "%" & val.filePath
  of vkUrl:      val.urlVal
  of vkEmail:    val.emailVal
  of vkBlock:
    var s = "["
    for i, v in val.blockVals:
      if i > 0: s &= " "
      s &= $v
    s & "]"
  of vkParen:
    var s = "("
    for i, v in val.parenVals:
      if i > 0: s &= " "
      s &= $v
    s & ")"
  of vkMap:      "map!"
  of vkSet:      "set!"
  of vkContext:  "context!"
  of vkPrototype: "prototype!"
  of vkFunction: "function!"
  of vkNative:   "native!:" & val.nativeFn.name
  of vkOp:       val.opSymbol
  of vkType:     val.typeName
  of vkWord:
    case val.wordKind
    of wkWord:     val.wordName
    of wkSetWord:  val.wordName & ":"
    of wkGetWord:  ":" & val.wordName
    of wkLitWord:  "'" & val.wordName
    of wkMetaWord: "@" & val.wordName

proc parseFuncSpec*(specBlock: seq[KtgValue]): ParsedFuncSpec =
  ## Parse a function spec block [a [type!] b /refine param] into params,
  ## refinements, and return type. Shared by interpreter, emitter, and prescan.
  var params: seq[ParamSpec] = @[]
  var refinements: seq[RefinementSpec] = @[]
  var returnType = ""
  var i = 0
  var inRefinement = false
  while i < specBlock.len:
    let s = specBlock[i]
    # Refinement declaration: /name
    if s.kind == vkWord and s.wordKind == wkWord and s.wordName.startsWith("/"):
      let refName = s.wordName[1..^1]
      refinements.add(RefinementSpec(name: refName, params: @[]))
      inRefinement = true
      i += 1
      continue
    if s.kind == vkWord and s.wordKind == wkWord:
      var pname = s.wordName
      var ptype = ""
      var elemType = ""
      # Check for type annotation block
      if i + 1 < specBlock.len and specBlock[i + 1].kind == vkBlock:
        i += 1
        let typeBlock = specBlock[i].blockVals
        if typeBlock.len > 0:
          if typeBlock.len == 2 and typeBlock[0].kind == vkType and
               typeBlock[0].typeName == "block!" and typeBlock[1].kind == vkType:
            ptype = "block!"
            elemType = typeBlock[1].typeName
          else:
            ptype = $typeBlock[0]
      if inRefinement:
        if refinements.len > 0:
          refinements[^1].params.add(ParamSpec(name: pname, typeName: ptype, elementType: elemType))
      else:
        params.add(ParamSpec(name: pname, typeName: ptype, elementType: elemType))
    elif s.kind == vkBlock:
      discard  # standalone type annotation (already consumed above)
    elif s.kind == vkWord and s.wordKind == wkSetWord and s.wordName == "return":
      i += 1
      if i < specBlock.len and specBlock[i].kind == vkBlock:
        let typeBlock = specBlock[i].blockVals
        if typeBlock.len > 0:
          returnType = $typeBlock[0]
    i += 1
  ParsedFuncSpec(params: params, refinements: refinements, returnType: returnType)
