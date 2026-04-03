## Kintsugi -> Lua code emitter.
##
## Walks the AST (seq[KtgValue]) and produces Lua source code as a string.
## No IR — the AST IS the IR. Same data structure the evaluator walks,
## the emitter walks too. This is the homoiconic design.
##
## Design decisions (from spec section 14):
##   - Zero-dependency Lua output. No LuaRocks.
##   - Type checks are ERASED — not emitted as runtime checks.
##   - `do`, `bind`, `compose` on dynamic blocks are COMPILE ERRORS.
##   - `match` specializes to if-chain.
##   - `object` specializes to table + constructor function.
##   - `loop` specializes to Lua for/ipairs loops.
##   - `#preprocess` runs at compile time (not in this file).
##   - `freeze`/`frozen?` are no-ops in compiled output.

import std/[strutils, tables, sequtils, sets, os]
import ../core/types
import ../parse/parser

type
  BindingKind* = enum
    bkCall    ## function call with N args
    bkConst   ## bare reference, no parens
    bkAlias   ## name mapping, emits as-is
    bkAssign  ## callback assignment target
    bkOverride ## function definition: emits `function lua.path(...)` form

  RefinementInfo* = object
    name*: string
    paramCount*: int

  BindingInfo* = object
    arity*: int          ## -1 = value (not callable), 0+ = function with N params
    isFunction*: bool    ## true = definitely a function, false = definitely a value
    isUnknown*: bool     ## true = couldn't determine (use heuristic)
    refinements*: seq[RefinementInfo]

  LuaEmitter = object
    indent: int
    output: string
    bindings: Table[string, BindingInfo]
    ## Track locally declared names. Undeclared names emit as globals.
    locals: HashSet[string]
    ## Map Kintsugi name -> Lua path for foreign bindings.
    nameMap: Table[string, string]
    ## Track the kind for each binding entry.
    bindingKinds: Table[string, BindingKind]
    ## Source directory for resolving require paths.
    sourceDir: string
    ## Modules currently being compiled (cycle detection).
    compiling: HashSet[string]
    ## Track which prelude helpers are actually used.
    usedHelpers: HashSet[string]

  EmitError* = ref object of CatchableError


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc pad(e: LuaEmitter): string =
  repeat("  ", e.indent)

proc useHelper(e: var LuaEmitter, name: string) =
  ## Mark a prelude helper as used. Dependencies are automatic:
  ## _is_none and _NONE depend on each other, unpack is always included.
  e.usedHelpers.incl(name)
  if name == "_is_none": e.usedHelpers.incl("_NONE")
  if name == "_NONE": e.usedHelpers.incl("_is_none")

proc ln(e: var LuaEmitter, s: string) =
  e.output &= e.pad & s & "\n"

proc raw(e: var LuaEmitter, s: string) =
  e.output &= s

proc getBinding(e: LuaEmitter, name: string): BindingInfo =
  if name in e.bindings: e.bindings[name]
  else: BindingInfo(arity: -1, isFunction: false, isUnknown: true)

proc arity(e: LuaEmitter, name: string): int =
  ## Return known arity, or -1 for unknown.
  let b = e.getBinding(name)
  if b.isFunction: b.arity
  elif b.isUnknown: -1
  else: -1

proc sanitize(name: string): string =
  ## Convert Kintsugi identifiers to valid Lua identifiers.
  ## foo? -> is_foo, foo! -> foo_bang, foo-bar -> foo_bar
  result = name
  # Handle trailing ?
  if result.endsWith("?"):
    result = "is_" & result[0..^2]
  # Handle trailing !
  if result.endsWith("!"):
    result = result[0..^2] & "_bang"
  # Replace hyphens with underscores
  result = result.replace("-", "_")
  # Replace / with . for path access
  # (handled separately in emitPath)

proc luaEscape(s: string): string =
  ## Escape a string for Lua string literals.
  result = ""
  for c in s:
    case c
    of '\\': result &= "\\\\"
    of '"': result &= "\\\""
    of '\n': result &= "\\n"
    of '\r': result &= "\\r"
    of '\t': result &= "\\t"
    of '\0': result &= "\\0"
    else: result &= c

# ---------------------------------------------------------------------------
# Native arity table — what the emitter needs to know about built-in funcs
# ---------------------------------------------------------------------------

proc nativeBinding(arity: int): BindingInfo =
  BindingInfo(arity: arity, isFunction: true, isUnknown: false)

proc initNativeBindings(): Table[string, BindingInfo] =
  result = initTable[string, BindingInfo]()
  # Output
  result["print"] = nativeBinding(1)
  result["probe"] = nativeBinding(1)
  result["assert"] = nativeBinding(1)
  # Control flow
  result["if"] = nativeBinding(2)       # condition block
  result["either"] = nativeBinding(3)   # condition true-block false-block
  result["unless"] = nativeBinding(2)   # condition block
  result["not"] = nativeBinding(1)
  result["return"] = nativeBinding(1)
  result["break"] = nativeBinding(0)
  # Type introspection
  result["type"] = nativeBinding(1)
  # Type predicates — all arity 1
  for name in ["integer", "float", "string", "logic", "none", "money",
               "pair", "tuple", "date", "time", "file", "url", "email",
               "block", "paren", "map", "set", "context", "object",
               "function", "native", "word", "type", "number"]:
    result[name & "?"] = nativeBinding(1)
  result["is?"] = nativeBinding(2)
  # Series
  result["size?"] = nativeBinding(1)
  result["length?"] = nativeBinding(1)
  result["empty?"] = nativeBinding(1)
  result["first"] = nativeBinding(1)
  result["second"] = nativeBinding(1)
  result["last"] = nativeBinding(1)
  result["pick"] = nativeBinding(2)
  result["append"] = nativeBinding(2)
  result["copy"] = nativeBinding(1)
  result["select"] = nativeBinding(2)
  result["has?"] = nativeBinding(2)
  result["find"] = nativeBinding(2)
  result["reverse"] = nativeBinding(1)
  result["insert"] = nativeBinding(3)
  result["remove"] = nativeBinding(2)
  # String ops
  result["join"] = nativeBinding(2)
  result["rejoin"] = nativeBinding(1)
  result["trim"] = nativeBinding(1)
  result["uppercase"] = nativeBinding(1)
  result["lowercase"] = nativeBinding(1)
  result["split"] = nativeBinding(2)
  result["replace"] = nativeBinding(3)
  result["substring"] = nativeBinding(3)
  result["starts-with?"] = nativeBinding(2)
  result["ends-with?"] = nativeBinding(2)
  result["byte"] = nativeBinding(1)
  result["char"] = nativeBinding(1)
  # Math
  result["abs"] = nativeBinding(1)
  result["negate"] = nativeBinding(1)
  result["min"] = nativeBinding(2)
  result["max"] = nativeBinding(2)
  result["round"] = nativeBinding(1)
  result["odd?"] = nativeBinding(1)
  result["even?"] = nativeBinding(1)
  result["sqrt"] = nativeBinding(1)
  result["sin"] = nativeBinding(1)
  result["cos"] = nativeBinding(1)
  result["tan"] = nativeBinding(1)
  result["asin"] = nativeBinding(1)
  result["acos"] = nativeBinding(1)
  result["atan2"] = nativeBinding(2)
  result["pow"] = nativeBinding(2)
  result["exp"] = nativeBinding(1)
  result["log"] = nativeBinding(1)
  result["log10"] = nativeBinding(1)
  result["to-degrees"] = nativeBinding(1)
  result["to-radians"] = nativeBinding(1)
  result["floor"] = nativeBinding(1)
  result["ceil"] = nativeBinding(1)
  result["random"] = nativeBinding(1)
  # Block evaluation
  result["reduce"] = nativeBinding(1)
  result["all"] = nativeBinding(1)
  result["any"] = nativeBinding(1)
  # Function creation
  result["function"] = nativeBinding(2)
  result["does"] = nativeBinding(1)
  # Context/Object
  result["context"] = nativeBinding(1)
  result["scope"] = nativeBinding(1)
  result["freeze"] = nativeBinding(1)
  result["frozen?"] = nativeBinding(1)
  result["words-of"] = nativeBinding(1)
  # Type conversion
  result["to"] = nativeBinding(2)
  # Apply
  result["apply"] = nativeBinding(2)
  # Sort
  result["sort"] = nativeBinding(1)
  # Set (destructuring)
  result["set"] = nativeBinding(2)
  # Error handling
  result["error"] = nativeBinding(3)
  result["try"] = nativeBinding(1)
  # Match
  result["match"] = nativeBinding(2)
  # Make
  result["make"] = nativeBinding(2)
  # IO
  result["read"] = nativeBinding(1)
  result["write"] = nativeBinding(2)
  result["dir?"] = nativeBinding(1)
  result["file?"] = nativeBinding(1)
  result["exit"] = nativeBinding(1)
  result["load"] = nativeBinding(1)
  result["save"] = nativeBinding(2)
  result["import"] = nativeBinding(1)
  result["exports"] = nativeBinding(1)
  # Set operations
  result["charset"] = nativeBinding(1)
  result["union"] = nativeBinding(2)
  result["intersect"] = nativeBinding(2)
  # Bindings is a compile-time dialect — handled specially in prescan
  result["bindings"] = nativeBinding(1)
  result["capture"] = nativeBinding(2)
  # Loop is a dialect — handled specially, not via arity

# ---------------------------------------------------------------------------
# Lua reserved words — if a Kintsugi identifier collides, prefix with _k_
# ---------------------------------------------------------------------------

const LuaReserved = [
  "and", "break", "do", "else", "elseif", "end", "false", "for",
  "function", "goto", "if", "in", "local", "nil", "not", "or",
  "repeat", "return", "then", "true", "until", "while"
].toHashSet

proc luaName(name: string): string =
  let s = sanitize(name)
  if s in LuaReserved:
    "_k_" & s
  else:
    s

proc resolvedName(e: LuaEmitter, name: string): string =
  ## If `name` is in the bindings nameMap, return the mapped Lua path.
  ## Otherwise, fall back to luaName.
  if name in e.nameMap:
    e.nameMap[name]
  else:
    luaName(name)

# ---------------------------------------------------------------------------
# Forward declarations
# ---------------------------------------------------------------------------

proc emitExpr(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string
proc emitBody(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false)
proc emitBlock(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false)
proc emitMatchExpr(e: var LuaEmitter, valueExpr: string, rulesBlock: seq[KtgValue]): string
proc emitAttemptExpr(e: var LuaEmitter, blk: seq[KtgValue]): string
proc emitEitherExpr(e: var LuaEmitter, cond: string, trueBlock, falseBlock: seq[KtgValue]): string
proc emitLuaModule*(ast: seq[KtgValue], sourceDir: string = "",
                    compiling: HashSet[string] = initHashSet[string]()): string
proc findExports(ast: seq[KtgValue]): seq[string]

# ---------------------------------------------------------------------------
# Infix operators
# ---------------------------------------------------------------------------

proc isInfixOp(val: KtgValue): bool =
  val.kind == vkOp or
    (val.kind == vkWord and val.wordKind == wkWord and val.wordName in ["and", "or"])

proc luaOp(op: string): string =
  case op
  of "=", "==": "=="
  of "<>": "~="
  of "%": "%"
  of "and": "and"
  of "or": "or"
  else: op  # +, -, *, /, <, >, <=, >= are the same

# ---------------------------------------------------------------------------
# Path helper
# ---------------------------------------------------------------------------

proc emitPath(name: string): string =
  let parts = name.split('/')
  result = luaName(parts[0])
  for i in 1 ..< parts.len:
    if parts[i].startsWith(":"):
      # Dynamic get-word segment: /:var → [var]
      result &= "[" & luaName(parts[i][1..^1]) & "]"
    else:
      result &= "." & luaName(parts[i])

# ---------------------------------------------------------------------------
# Emit a single literal value as a Lua expression string
# ---------------------------------------------------------------------------

proc emitLiteral(val: KtgValue): string =
  case val.kind
  of vkInteger:
    $val.intVal
  of vkFloat:
    $val.floatVal
  of vkString:
    "\"" & luaEscape(val.strVal) & "\""
  of vkLogic:
    if val.boolVal: "true" else: "false"
  of vkNone:
    "nil"
  of vkMoney:
    # Emit as integer cents
    $val.cents
  of vkPair:
    # Emit as {x=N, y=M}
    "{x=" & $val.px & ", y=" & $val.py & "}"
  of vkTuple:
    # Emit as {v1, v2, v3, ...}
    var parts: seq[string] = @[]
    for v in val.tupleVals:
      parts.add($v)
    "{" & parts.join(", ") & "}"
  else:
    raise EmitError(msg: "cannot emit literal of type " & typeName(val))

# ---------------------------------------------------------------------------
# Emit a Kintsugi block [...] as a Lua table literal {v1, v2, ...}
# ---------------------------------------------------------------------------

proc emitBlockLiteral(e: var LuaEmitter, vals: seq[KtgValue]): string =
  ## Emit a block's contents as a Lua table.
  ## Each element is emitted as a literal or word reference.
  ## Uses _NONE instead of nil to preserve array indices.
  var parts: seq[string] = @[]
  var pos = 0
  while pos < vals.len:
    let expr = e.emitExpr(vals, pos)
    # Replace nil with _NONE in array contexts so Lua preserves the element
    if expr == "nil":
      e.useHelper("_NONE")
      parts.add("_NONE")
    else:
      parts.add(expr)
  "{" & parts.join(", ") & "}"

# ---------------------------------------------------------------------------
# Emit a context block as a Lua table {field1=val1, field2=val2}
# ---------------------------------------------------------------------------

proc emitContextBlock(e: var LuaEmitter, vals: seq[KtgValue]): string =
  ## Walk a block that contains set-word: value pairs and emit as a Lua table.
  var parts: seq[string] = @[]
  var pos = 0
  while pos < vals.len:
    let v = vals[pos]
    if v.kind == vkWord and v.wordKind == wkSetWord:
      pos += 1
      let fieldName = luaName(v.wordName)
      let value = e.emitExpr(vals, pos)
      parts.add(fieldName & " = " & value)
    else:
      pos += 1
  "{\n" & parts.mapIt(repeat("  ", e.indent + 1) & it).join(",\n") & "\n" & e.pad & "}"

# ---------------------------------------------------------------------------
# Shared function spec parser
# ---------------------------------------------------------------------------

type
  ParsedSpec = object
    params: seq[string]
    refinements: seq[tuple[name: string, params: seq[string]]]
    returnType: string

proc parseSpec(specBlock: seq[KtgValue]): ParsedSpec =
  ## Parse a function spec block into params, refinements, and return type.
  var params: seq[string] = @[]
  var refinements: seq[tuple[name: string, params: seq[string]]] = @[]
  var returnType = ""
  var i = 0
  var inRefinement = false
  while i < specBlock.len:
    let s = specBlock[i]
    if s.kind == vkWord and s.wordKind == wkWord and s.wordName.startsWith("/"):
      let refName = s.wordName[1..^1]
      refinements.add((name: refName, params: @[]))
      inRefinement = true
      i += 1
      continue
    if s.kind == vkWord and s.wordKind == wkWord:
      if inRefinement:
        refinements[^1].params.add(luaName(s.wordName))
      else:
        params.add(luaName(s.wordName))
    elif s.kind == vkBlock:
      discard  # type annotation
    elif s.kind == vkWord and s.wordKind == wkSetWord and s.wordName == "return":
      i += 1
      if i < specBlock.len and specBlock[i].kind == vkBlock:
        let typeBlock = specBlock[i].blockVals
        if typeBlock.len > 0:
          returnType = $typeBlock[0]
    elif s.kind == vkWord and s.wordKind == wkSetWord:
      # Other set-words in spec — skip
      discard
    i += 1
  ParsedSpec(params: params, refinements: refinements, returnType: returnType)

proc allLuaParams(spec: ParsedSpec): seq[string] =
  ## Full Lua param list: regular params + refinement flags + refinement params.
  result = spec.params
  for r in spec.refinements:
    result.add(luaName(r.name))
    for rp in r.params:
      result.add(rp)

# ---------------------------------------------------------------------------
# Emit function definition
# ---------------------------------------------------------------------------

proc emitFuncDef(e: var LuaEmitter, specBlock, bodyBlock: seq[KtgValue]): string =
  ## Parse a function spec [a b] and body [...] into a Lua function expression.
  let spec = parseSpec(specBlock)
  let params = spec.allLuaParams()

  let paramStr = params.join(", ")
  var funcStr = "function(" & paramStr & ")\n"

  # Save and reset locals for the new function scope
  let savedLocals = e.locals
  e.locals = initHashSet[string]()
  # Parameters are locals in the function scope
  for p in params:
    e.locals.incl(p)

  e.indent += 1
  # Emit body — last expression is implicit return
  e.emitBody(bodyBlock, asReturn = true)
  let bodyStr = e.output
  e.output = ""
  e.indent -= 1

  # Restore outer locals
  e.locals = savedLocals

  # Record arity for this function (caller will associate with name)
  funcStr &= bodyStr
  funcStr &= e.pad & "end"
  funcStr

# ---------------------------------------------------------------------------
# Emit loop dialect
# ---------------------------------------------------------------------------

proc skipDo(blk: seq[KtgValue], pos: var int) =
  ## Skip optional 'do' keyword before body block
  if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "do":
    pos += 1

proc emitLoopBody(e: var LuaEmitter, bodyVals: seq[KtgValue], refinement: string,
                  iterVar: string) =
  ## Emit the loop body, wrapping for collect/fold/partition refinements.
  case refinement
  of "collect":
    # Body result appended to result table
    e.ln("_collect_r[#_collect_r+1] = (function()")
    e.indent += 1
    e.emitBlock(bodyVals, asReturn = true)
    e.indent -= 1
    e.ln("end)()")
  of "fold":
    # Body result becomes new accumulator
    e.ln("_fold_acc = (function()")
    e.indent += 1
    e.emitBlock(bodyVals, asReturn = true)
    e.indent -= 1
    e.ln("end)()")
  of "partition":
    # Body is predicate — element goes to true or false bucket
    e.ln("if (function()")
    e.indent += 1
    e.emitBlock(bodyVals, asReturn = true)
    e.indent -= 1
    e.ln("end)() then")
    e.indent += 1
    e.ln("_part_true[#_part_true+1] = " & iterVar)
    e.indent -= 1
    e.ln("else")
    e.indent += 1
    e.ln("_part_false[#_part_false+1] = " & iterVar)
    e.indent -= 1
    e.ln("end")
  else:
    e.emitBlock(bodyVals)

proc emitLoop(e: var LuaEmitter, blk: seq[KtgValue], refinement: string = ""): string =
  ## Emit a loop. Returns result variable name for collect/fold/partition, "" otherwise.
  result = ""

  # Set up result variables for refinements
  case refinement
  of "collect":
    result = "_collect_r"
    e.ln("local _collect_r = {}")
  of "fold":
    result = "_fold_acc"
  of "partition":
    result = "{_part_true, _part_false}"
    e.ln("local _part_true = {}")
    e.ln("local _part_false = {}")
  else: discard

  var pos = 0

  # Check for 'for' keyword
  if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "for":
    pos += 1

    # Variable binding block
    var vars: seq[string] = @[]
    if pos < blk.len and blk[pos].kind == vkBlock:
      for v in blk[pos].blockVals:
        if v.kind == vkWord: vars.add(luaName(v.wordName))
      pos += 1

    # 'in' or 'from'
    if pos < blk.len and blk[pos].kind == vkWord:
      case blk[pos].wordName
      of "in":
        # for [v] in series [body]
        pos += 1
        let series = e.emitExpr(blk, pos)
        # optional 'when' guard
        var guard = ""
        if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "when":
          pos += 1
          if pos < blk.len and blk[pos].kind == vkBlock:
            var guardPos = 0
            guard = e.emitExpr(blk[pos].blockVals, guardPos)
            pos += 1

        skipDo(blk, pos)
        if pos < blk.len and blk[pos].kind == vkBlock:
          let iterVar = if vars.len > 0: vars[0] else: "_"
          # fold: initialize accumulator to first element, iterate from 2
          if refinement == "fold":
            e.ln("local _fold_acc = " & series & "[1]")
            let accVar = if vars.len >= 2: vars[0] else: iterVar
            let elemVar = if vars.len >= 2: vars[1] else: iterVar
            e.ln("for _i = 2, #" & series & " do")
            e.indent += 1
            e.ln("local " & elemVar & " = " & series & "[_i]")
            if vars.len >= 2:
              e.ln("local " & accVar & " = _fold_acc")
            if guard.len > 0:
              e.ln("if " & guard & " then")
              e.indent += 1
              e.emitLoopBody(blk[pos].blockVals, refinement, elemVar)
              e.indent -= 1
              e.ln("end")
            else:
              e.emitLoopBody(blk[pos].blockVals, refinement, elemVar)
            e.indent -= 1
            e.ln("end")
          else:
            let varStr = if vars.len > 0: "_, " & vars[0] else: "_"
            e.ln("for " & varStr & " in ipairs(" & series & ") do")
            e.indent += 1
            if guard.len > 0:
              e.ln("if " & guard & " then")
              e.indent += 1
              e.emitLoopBody(blk[pos].blockVals, refinement, if vars.len > 0: vars[0] else: "_")
              e.indent -= 1
              e.ln("end")
            else:
              e.emitLoopBody(blk[pos].blockVals, refinement, if vars.len > 0: vars[0] else: "_")
            e.indent -= 1
            e.ln("end")

      of "from":
        # for [i] from N to M [by S] [body]
        pos += 1
        let fromExpr = e.emitExpr(blk, pos)
        var toExpr = ""
        var stepExpr = ""
        # expect 'to'
        if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "to":
          pos += 1
          toExpr = e.emitExpr(blk, pos)
        # optional 'by'
        if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "by":
          pos += 1
          stepExpr = e.emitExpr(blk, pos)

        # optional 'when' guard
        var guard = ""
        if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "when":
          pos += 1
          if pos < blk.len and blk[pos].kind == vkBlock:
            var guardPos = 0
            guard = e.emitExpr(blk[pos].blockVals, guardPos)
            pos += 1

        skipDo(blk, pos)
        if pos < blk.len and blk[pos].kind == vkBlock:
          let varName = if vars.len > 0: vars[0] else: "_"
          var forHeader = "for " & varName & " = " & fromExpr & ", " & toExpr
          if stepExpr.len > 0:
            forHeader &= ", " & stepExpr
          e.ln(forHeader & " do")
          e.indent += 1
          if guard.len > 0:
            e.ln("if " & guard & " then")
            e.indent += 1
            e.emitLoopBody(blk[pos].blockVals, refinement, varName)
            e.indent -= 1
            e.ln("end")
          else:
            e.emitLoopBody(blk[pos].blockVals, refinement, varName)
          e.indent -= 1
          e.ln("end")
      else: discard

  elif pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "from":
    # from/to without explicit 'for' — uses 'it' as implicit var
    pos += 1
    let fromExpr = e.emitExpr(blk, pos)
    var toExpr = ""
    var stepExpr = ""
    if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "to":
      pos += 1
      toExpr = e.emitExpr(blk, pos)
    if pos < blk.len and blk[pos].kind == vkWord and blk[pos].wordName == "by":
      pos += 1
      stepExpr = e.emitExpr(blk, pos)
    skipDo(blk, pos)
    if pos < blk.len and blk[pos].kind == vkBlock:
      var forHeader = "for it = " & fromExpr & ", " & toExpr
      if stepExpr.len > 0:
        forHeader &= ", " & stepExpr
      e.ln(forHeader & " do")
      e.indent += 1
      e.emitLoopBody(blk[pos].blockVals, refinement, "it")
      e.indent -= 1
      e.ln("end")

  else:
    # Infinite loop: while true do ... end
    # But first check if the content itself starts with control flow
    # (the outer block IS the loop body)
    if blk.len > 0:
      e.ln("while true do")
      e.indent += 1
      e.emitBlock(blk)
      e.indent -= 1
      e.ln("end")

# ---------------------------------------------------------------------------
# Emit match as if-chain (statement form)
# ---------------------------------------------------------------------------

proc emitMatchStmt(e: var LuaEmitter, valueExpr: string, rulesBlock: seq[KtgValue],
                   asReturn: bool = false) =
  ## match value [...rules...] as a statement. If asReturn, emit return in handlers.
  var pos = 0
  var first = true

  while pos < rulesBlock.len:
    let current = rulesBlock[pos]

    # default: handler
    if current.kind == vkWord and current.wordKind == wkSetWord and
       current.wordName == "default":
      pos += 1
      if pos < rulesBlock.len and rulesBlock[pos].kind == vkBlock:
        if first:
          e.ln("do")
        else:
          e.ln("else")
        e.indent += 1
        if asReturn:
          e.emitBlock(rulesBlock[pos].blockVals, asReturn = true)
        else:
          e.emitBlock(rulesBlock[pos].blockVals)
        e.indent -= 1
        pos += 1
      # Don't emit end here — the loop-end handler at line 688 does it
      continue

    # Expect pattern block
    if current.kind != vkBlock:
      pos += 1
      continue

    let pattern = current.blockVals
    pos += 1

    # Optional 'when' guard
    var guardExpr = ""
    if pos < rulesBlock.len and rulesBlock[pos].kind == vkWord and
       rulesBlock[pos].wordKind == wkWord and rulesBlock[pos].wordName == "when":
      pos += 1
      if pos < rulesBlock.len and rulesBlock[pos].kind == vkBlock:
        var gpos = 0
        guardExpr = e.emitExpr(rulesBlock[pos].blockVals, gpos)
        pos += 1

    # Expect handler block
    if pos >= rulesBlock.len or rulesBlock[pos].kind != vkBlock:
      continue
    let handler = rulesBlock[pos].blockVals
    pos += 1

    # Build the condition expression from the pattern
    var conditions: seq[string] = @[]
    var bindings: seq[(string, string)] = @[]  # (lua_name, expr)

    if pattern.len == 1:
      let p = pattern[0]
      case p.kind
      of vkInteger, vkFloat, vkString, vkLogic, vkNone, vkMoney:
        conditions.add(valueExpr & " == " & emitLiteral(p))
      of vkType:
        # Type match — emit a type() check
        let luaType = case p.typeName
          of "integer!": "\"number\""
          of "float!": "\"number\""
          of "string!": "\"string\""
          of "logic!": "\"boolean\""
          of "none!": "\"nil\""
          of "block!": "\"table\""
          else: "\"" & p.typeName & "\""
        conditions.add("type(" & valueExpr & ") == " & luaType)
      of vkWord:
        if p.wordKind == wkWord and p.wordName == "_":
          discard  # wildcard — always matches
        elif p.wordKind == wkWord:
          # Capture — bind value to name
          bindings.add((luaName(p.wordName), valueExpr))
        elif p.wordKind == wkLitWord:
          conditions.add(valueExpr & " == \"" & p.wordName & "\"")
      else:
        discard
    else:
      # Multi-element pattern — destructuring match against a table
      for i, p in pattern:
        let elemExpr = valueExpr & "[" & $(i + 1) & "]"
        case p.kind
        of vkInteger, vkFloat, vkString, vkLogic, vkNone, vkMoney:
          conditions.add(elemExpr & " == " & emitLiteral(p))
        of vkType:
          let luaType = case p.typeName
            of "integer!": "\"number\""
            of "float!": "\"number\""
            of "string!": "\"string\""
            of "logic!": "\"boolean\""
            else: "\"table\""
          conditions.add("type(" & elemExpr & ") == " & luaType)
        of vkWord:
          if p.wordKind == wkWord and p.wordName != "_":
            bindings.add((luaName(p.wordName), elemExpr))
        else:
          discard

    if guardExpr.len > 0:
      conditions.add(guardExpr)

    let keyword = if first: "if" else: "elseif"
    let condStr = if conditions.len > 0: conditions.join(" and ") else: "true"
    e.ln(keyword & " " & condStr & " then")
    e.indent += 1

    # Emit bindings as locals
    for (name, expr) in bindings:
      e.ln("local " & name & " = " & expr)

    if asReturn:
      e.emitBlock(handler, asReturn = true)
    else:
      e.emitBlock(handler)
    e.indent -= 1
    first = false

  if not first:
    e.ln("end")

# ---------------------------------------------------------------------------
# Emit match as expression (returns a value via IIFE)
# ---------------------------------------------------------------------------

proc emitMatchExpr(e: var LuaEmitter, valueExpr: string, rulesBlock: seq[KtgValue]): string =
  ## match value [...rules...] as an expression that produces a value.
  ## Emits as (function() if ... return ... elseif ... return ... end end)()
  var pos = 0
  var first = true
  var code = "(function()\n"
  let baseIndent = e.pad

  while pos < rulesBlock.len:
    let current = rulesBlock[pos]

    if current.kind == vkWord and current.wordKind == wkSetWord and
       current.wordName == "default":
      pos += 1
      if pos < rulesBlock.len and rulesBlock[pos].kind == vkBlock:
        if first:
          # no condition needed
          discard
        else:
          code &= baseIndent & "  else\n"
        # emit handler body with return on last expr
        let saved = e.output
        e.output = ""
        let savedIndent = e.indent
        e.indent = e.indent + 2
        e.emitBody(rulesBlock[pos].blockVals, asReturn = true)
        code &= e.output
        e.output = saved
        e.indent = savedIndent
        pos += 1
      if not first:
        code &= baseIndent & "  end\n"
      continue

    if current.kind != vkBlock:
      pos += 1
      continue

    let pattern = current.blockVals
    pos += 1

    # Optional 'when' guard
    var guardExpr = ""
    if pos < rulesBlock.len and rulesBlock[pos].kind == vkWord and
       rulesBlock[pos].wordKind == wkWord and rulesBlock[pos].wordName == "when":
      pos += 1
      if pos < rulesBlock.len and rulesBlock[pos].kind == vkBlock:
        var gpos = 0
        guardExpr = e.emitExpr(rulesBlock[pos].blockVals, gpos)
        pos += 1

    if pos >= rulesBlock.len or rulesBlock[pos].kind != vkBlock:
      continue
    let handler = rulesBlock[pos].blockVals
    pos += 1

    # Build condition
    var conditions: seq[string] = @[]
    var bindings: seq[(string, string)] = @[]

    if pattern.len == 1:
      let p = pattern[0]
      case p.kind
      of vkInteger, vkFloat, vkString, vkLogic, vkNone, vkMoney:
        conditions.add(valueExpr & " == " & emitLiteral(p))
      of vkWord:
        if p.wordKind == wkWord and p.wordName == "_":
          discard
        elif p.wordKind == wkWord:
          bindings.add((luaName(p.wordName), valueExpr))
        elif p.wordKind == wkLitWord:
          conditions.add(valueExpr & " == \"" & p.wordName & "\"")
      else:
        discard

    if guardExpr.len > 0:
      conditions.add(guardExpr)

    let keyword = if first: "if" else: "elseif"
    let condStr = if conditions.len > 0: conditions.join(" and ") else: "true"
    code &= baseIndent & "  " & keyword & " " & condStr & " then\n"

    # Emit bindings
    for (name, expr) in bindings:
      code &= baseIndent & "    local " & name & " = " & expr & "\n"

    # Emit handler body with return
    let saved = e.output
    e.output = ""
    let savedIndent = e.indent
    e.indent = e.indent + 2
    e.emitBody(handler, asReturn = true)
    code &= e.output
    e.output = saved
    e.indent = savedIndent
    first = false

  if not first:
    code &= baseIndent & "  end\n"
  code &= baseIndent & "end)()"
  result = code

# ---------------------------------------------------------------------------
# Emit either as expression
# ---------------------------------------------------------------------------

proc emitEitherExpr(e: var LuaEmitter, cond: string, trueBlock, falseBlock: seq[KtgValue]): string =
  ## Emit either as expression. For simple single-expression blocks, use
  ## the Lua ternary idiom (cond and trueVal or falseVal). For complex
  ## blocks, use an IIFE.
  # Check if both blocks are simple single expressions
  if trueBlock.len <= 2 and falseBlock.len <= 2:
    # Try simple ternary
    var tpos = 0
    let trueExpr = e.emitExpr(trueBlock, tpos)
    var fpos = 0
    let falseExpr = e.emitExpr(falseBlock, fpos)
    # Simple ternary only works if true value is not false/nil
    result = "(" & cond & " and " & trueExpr & " or " & falseExpr & ")"
  else:
    # Complex: use IIFE
    let baseIndent = e.pad
    var code = "(function()\n"
    code &= baseIndent & "  if " & cond & " then\n"
    let saved = e.output
    e.output = ""
    let savedIndent = e.indent
    e.indent = e.indent + 2
    e.emitBody(trueBlock, asReturn = true)
    code &= e.output
    e.output = saved
    e.indent = savedIndent
    code &= baseIndent & "  else\n"
    e.output = ""
    e.indent = e.indent + 2
    e.emitBody(falseBlock, asReturn = true)
    code &= e.output
    e.output = saved
    e.indent = savedIndent
    code &= baseIndent & "  end\n"
    code &= baseIndent & "end)()"
    result = code

# ---------------------------------------------------------------------------
# Emit attempt dialect as pcall chain
# ---------------------------------------------------------------------------

proc emitAttemptExpr(e: var LuaEmitter, blk: seq[KtgValue]): string =
  ## Emit an attempt pipeline as a pcall-based expression.
  ## attempt [source [...] then [...] when [...] catch 'kind [...] fallback [...] retries N]
  var sourceBody: seq[KtgValue] = @[]
  var thenBodies: seq[seq[KtgValue]] = @[]
  var whenBodies: seq[seq[KtgValue]] = @[]
  var catches: seq[(string, seq[KtgValue])] = @[]
  var fallbackBody: seq[KtgValue] = @[]
  var retryCount = 0
  var hasSource = false

  # Parse the pipeline block
  var ppos = 0
  while ppos < blk.len:
    let cur = blk[ppos]
    if cur.kind == vkWord and cur.wordKind == wkWord:
      case cur.wordName
      of "source":
        ppos += 1
        if ppos < blk.len and blk[ppos].kind == vkBlock:
          sourceBody = blk[ppos].blockVals
          hasSource = true
          ppos += 1
      of "then":
        ppos += 1
        if ppos < blk.len and blk[ppos].kind == vkBlock:
          thenBodies.add(blk[ppos].blockVals)
          ppos += 1
      of "when":
        ppos += 1
        if ppos < blk.len and blk[ppos].kind == vkBlock:
          whenBodies.add(blk[ppos].blockVals)
          ppos += 1
      of "catch":
        ppos += 1
        if ppos < blk.len and blk[ppos].kind == vkWord and blk[ppos].wordKind == wkLitWord:
          let errorKind = blk[ppos].wordName
          ppos += 1
          if ppos < blk.len and blk[ppos].kind == vkBlock:
            catches.add((errorKind, blk[ppos].blockVals))
            ppos += 1
      of "fallback":
        ppos += 1
        if ppos < blk.len and blk[ppos].kind == vkBlock:
          fallbackBody = blk[ppos].blockVals
          ppos += 1
      of "retries":
        ppos += 1
        if ppos < blk.len and blk[ppos].kind == vkInteger:
          retryCount = int(blk[ppos].intVal)
          ppos += 1
      else:
        ppos += 1
    else:
      ppos += 1

  if not hasSource:
    # No source → return a function (pipeline factory)
    # For now, emit as compile error since closures need runtime eval
    return "nil  --[[ attempt without source not compiled ]]"

  let baseIndent = e.pad
  var code = "(function()\n"

  # Emit source + then chain wrapped in pcall for error handling
  let saved = e.output
  let savedIndent = e.indent

  # If retries, wrap in a for loop
  if retryCount > 0:
    code &= baseIndent & "  for _attempt = 1, " & $(retryCount + 1) & " do\n"
    e.indent = savedIndent + 2
  else:
    e.indent = savedIndent + 1

  let bodyIndent = repeat("  ", e.indent)

  # Emit: local ok, it = pcall(function() <source> end)
  e.output = ""
  e.indent += 1
  e.emitBlock(sourceBody, asReturn = true)
  let srcCode = e.output
  code &= bodyIndent & "local _ok, it = pcall(function()\n"
  code &= srcCode
  code &= bodyIndent & "end)\n"
  code &= bodyIndent & "if not _ok then\n"

  # Error handling: check catches, then fallback
  if catches.len > 0 or fallbackBody.len > 0:
    e.indent = savedIndent + (if retryCount > 0: 3 else: 2)
    let errIndent = repeat("  ", e.indent)
    if retryCount > 0:
      code &= errIndent & "if _attempt < " & $(retryCount + 1) & " then\n"
      code &= errIndent & "  -- retry\n"
      code &= errIndent & "else\n"
      e.indent += 1
    if fallbackBody.len > 0:
      e.output = ""
      e.indent += 1
      e.emitBlock(fallbackBody, asReturn = true)
      let fbCode = e.output
      code &= repeat("  ", e.indent - 1) & "return (function() local error = it\n"
      code &= fbCode
      code &= repeat("  ", e.indent - 1) & "end)()\n"
    else:
      code &= repeat("  ", e.indent) & "error(it)\n"
    if retryCount > 0:
      code &= errIndent & "end\n"
  else:
    code &= bodyIndent & "  error(it)\n"
  code &= bodyIndent & "end\n"

  # Emit then steps
  for thenBody in thenBodies:
    e.output = ""
    e.indent = savedIndent + (if retryCount > 0: 3 else: 2)
    e.emitBlock(thenBody, asReturn = true)
    let thenCode = e.output
    code &= bodyIndent & "it = (function()\n"
    code &= thenCode
    code &= bodyIndent & "end)()\n"

  # Emit when guards
  for whenBody in whenBodies:
    e.output = ""
    e.indent = savedIndent + (if retryCount > 0: 3 else: 2)
    var wpos = 0
    let guardExpr = e.emitExpr(whenBody, wpos)
    code &= bodyIndent & "if not (" & guardExpr & ") then return nil end\n"

  code &= bodyIndent & "return it\n"

  if retryCount > 0:
    code &= baseIndent & "  end\n"

  code &= baseIndent & "end)()"
  e.output = saved
  e.indent = savedIndent
  result = code

# ---------------------------------------------------------------------------
# Compile-error guards for interpreter-only features
# ---------------------------------------------------------------------------

proc compileError(feature, hint: string, line: int) =
  raise EmitError(
    msg: "======== COMPILE ERROR ========\n" &
         "Interpreter-Only Feature\n" &
         "'" & feature & "' cannot be used in compiled output -- it requires runtime evaluation" &
         (if line > 0: " @ line " & $line else: "") & "\n" &
         "  hint: " & hint
  )

# ---------------------------------------------------------------------------
# Check if a word-name refers to a "none?" type predicate
# ---------------------------------------------------------------------------

proc isTypePredicate(name: string): bool =
  ## Return true if name is a type-predicate like "none?", "integer?", etc.
  name.endsWith("?") and name[0..^2] in [
    "none", "integer", "float", "string", "logic", "money",
    "pair", "tuple", "date", "time", "file", "url", "email",
    "block", "paren", "map", "set", "context", "object",
    "function", "native", "word", "type", "number"
  ]

proc needsParens(expr: string): bool =
  ## Check if an expression needs wrapping in parens for use as an operand.
  ## Needed when the expression contains and/or which have lower precedence than ==.
  " and " in expr or " or " in expr

proc emitTypePredicateCall(e: var LuaEmitter, name: string, argExpr: string): string =
  ## Emit a type predicate as an efficient Lua expression.
  let baseName = name[0..^2]  # strip trailing ?
  let safeArg = if needsParens(argExpr): "(" & argExpr & ")" else: argExpr
  case baseName
  of "none":
    e.useHelper("_is_none")
    result = "_is_none(" & safeArg & ")"
  of "integer":
    result = "(type(" & argExpr & ") == \"number\" and math.floor(" & argExpr & ") == " & argExpr & ")"
  of "float":
    result = "(type(" & argExpr & ") == \"number\")"
  of "string":
    result = "(type(" & argExpr & ") == \"string\")"
  of "logic":
    result = "(type(" & argExpr & ") == \"boolean\")"
  of "block", "context", "object", "map":
    result = "(type(" & argExpr & ") == \"table\")"
  of "function", "native":
    result = "(type(" & argExpr & ") == \"function\")"
  of "number":
    result = "(type(" & argExpr & ") == \"number\")"
  else:
    # Generic fallback
    result = "(type(" & argExpr & ") == \"" & baseName & "\")"

# ---------------------------------------------------------------------------
# Core expression emitter — returns a Lua expression string
# ---------------------------------------------------------------------------

proc emitExpr(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  ## Emit the next expression from vals starting at pos. Returns a Lua
  ## expression string and advances pos past the consumed values.
  ## Greedily consumes infix operators (matching evaluator's evalNext + applyInfix).
  if pos >= vals.len:
    return "nil"

  let val = vals[pos]
  pos += 1

  case val.kind

  # --- Literals ---
  of vkInteger, vkFloat, vkString, vkLogic, vkNone, vkMoney, vkPair, vkTuple:
    result = emitLiteral(val)

  # --- Block: emit as Lua table ---
  of vkBlock:
    result = e.emitBlockLiteral(val.blockVals)

  # --- Paren: emit contents as grouped expression ---
  of vkParen:
    var ppos = 0
    let inner = e.emitExpr(val.parenVals, ppos)
    result = "(" & inner & ")"

  # --- Op: shouldn't appear here, handled by infix ---
  of vkOp:
    result = luaOp(val.opSymbol)

  # --- Word ---
  of vkWord:
    case val.wordKind

    of wkSetWord:
      # x: expr -> should be handled at statement level, but handle here for
      # nested contexts. Return the expression value.
      let rhs = e.emitExpr(vals, pos)
      result = rhs  # the assignment is done at statement level

    of wkGetWord:
      result = luaName(val.wordName)

    of wkLitWord:
      result = "\"" & val.wordName & "\""

    of wkMetaWord:
      # Meta-words are erased in compiled output
      result = "nil"

    of wkWord:
      let name = val.wordName

      # --- raw: write string verbatim to Lua output ---
      if name == "raw":
        let arg = e.emitExpr(vals, pos)
        # Strip quotes from string literal
        if arg.startsWith("\"") and arg.endsWith("\""):
          result = arg[1..^2]
        else:
          result = arg

      # --- Known native refinement calls ---
      elif name == "round/down":
        let arg = e.emitExpr(vals, pos)
        result = "math.floor(" & arg & ")"
      elif name == "round/up":
        let arg = e.emitExpr(vals, pos)
        result = "math.ceil(" & arg & ")"
      elif name == "copy/deep":
        let arg = e.emitExpr(vals, pos)
        e.useHelper("_deep_copy")
        result = "_deep_copy(" & arg & ")"
      elif name == "sort/by":
        let arr = e.emitExpr(vals, pos)
        let keyFn = e.emitExpr(vals, pos)
        result = "(function() table.sort(" & arr & ", function(a, b) return " & keyFn & "(a) < " & keyFn & "(b) end); return " & arr & " end)()"
      elif name == "sort/with":
        let arr = e.emitExpr(vals, pos)
        let cmpFn = e.emitExpr(vals, pos)
        result = "(function() table.sort(" & arr & ", " & cmpFn & "); return " & arr & " end)()"
      elif name == "try/handle":
        # try/handle [body] [handler] — handler receives error as 'it'
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          # Handler block — evaluated with 'it' bound to error
          var handlerBody = ""
          if pos < vals.len and vals[pos].kind == vkBlock:
            let hblk = vals[pos].blockVals
            pos += 1
            let saved = e.output
            e.output = ""
            e.indent += 2
            e.emitBody(hblk, asReturn = true)
            handlerBody = e.output
            e.output = saved
          let saved = e.output
          e.output = ""
          e.indent += 1
          e.emitBody(blk, asReturn = true)
          let bodyStr = e.output
          e.output = saved
          e.indent -= 1
          result = "(function()\n" &
                   e.pad & "  local ok, it = pcall(function()\n" &
                   bodyStr &
                   e.pad & "  end)\n" &
                   e.pad & "  if ok then return it\n" &
                   e.pad & "  else\n" &
                   handlerBody &
                   e.pad & "  end\n" &
                   e.pad & "end)()"
        else:
          result = "nil"
      elif name == "freeze/deep":
        # No-op in compiled output, just pass through
        result = e.emitExpr(vals, pos)

      # --- Dialect refinement paths (must come before generic path handler) ---
      elif name.startsWith("loop/") and name.split('/')[1] in ["collect", "fold", "partition"]:
        let refinement = name.split('/')[1]
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          let saved = e.output
          e.output = ""
          e.indent += 1
          let resultVar = e.emitLoop(blk, refinement)
          e.ln("return " & resultVar)
          let loopCode = e.output
          e.output = saved
          e.indent -= 1
          result = "(function()\n" & loopCode & e.pad & "end)()"
        else:
          result = "nil"

      # --- system/platform → compile-time constant ---
      elif name == "system/platform":
        result = "\"lua\""

      # --- system/env/NAME → os.getenv("NAME") ---
      elif name.startsWith("system/env/"):
        let envName = name.split('/')[2]
        result = "os.getenv(\"" & envName & "\")"

      # --- Path access or call: obj/field/sub ---
      elif name.contains('/'):
        let parts = name.split('/')
        let head = parts[0]
        let path = emitPath(name)
        let headBinding = e.getBinding(head)
        let fullBinding = e.getBinding(name)

        if fullBinding.isFunction and not fullBinding.isUnknown:
          # Whole path is a known binding (from bindings dialect)
          var args: seq[string] = @[]
          for i in 0 ..< fullBinding.arity:
            args.add(e.emitExpr(vals, pos))
          result = path & "(" & args.join(", ") & ")"
        elif headBinding.isFunction and not headBinding.isUnknown:
          # Head is a known function — refinement call
          let refNames = parts[1..^1]
          var args: seq[string] = @[]
          # Consume regular args
          for i in 0 ..< headBinding.arity:
            args.add(e.emitExpr(vals, pos))
          # Emit refinement flags and params
          if headBinding.refinements.len > 0:
            for r in headBinding.refinements:
              let active = r.name in refNames
              args.add(if active: "true" else: "false")
              if active:
                for j in 0 ..< r.paramCount:
                  args.add(e.emitExpr(vals, pos))
              else:
                for j in 0 ..< r.paramCount:
                  args.add("nil")
          result = e.resolvedName(head) & "(" & args.join(", ") & ")"
        elif not headBinding.isFunction and not headBinding.isUnknown:
          # Head is a known value — pure field access, no arg consumption
          result = path
        else:
          # Unknown path — default to field access (safe: won't consume args)
          result = path

      # --- Interpreter-only features: compile error ---
      # --- No-ops: freeze/frozen? ---
      elif name == "freeze":
        result = e.emitExpr(vals, pos)

      elif name == "frozen?":
        discard e.emitExpr(vals, pos)
        result = "false"

      # --- print ---
      elif name == "print":
        let arg = e.emitExpr(vals, pos)
        result = "print(" & arg & ")"

      # --- probe (returns value) ---
      elif name == "probe":
        let arg = e.emitExpr(vals, pos)
        result = "(function() local _v = " & arg & "; print(_v); return _v end)()"

      # --- not ---
      elif name == "not":
        let arg = e.emitExpr(vals, pos)
        # Wrap predicate calls in parens to ensure correct precedence
        if arg.startsWith("(") or arg.startsWith("not "):
          result = "not " & arg
        else:
          result = "not (" & arg & ")"

      # --- return ---
      elif name == "return":
        let arg = e.emitExpr(vals, pos)
        result = "return " & arg  # Note: used at statement level typically

      # --- if: condition block ---
      elif name == "if":
        let cond = e.emitExpr(vals, pos)
        if pos < vals.len and vals[pos].kind == vkBlock:
          let bodyBlock = vals[pos].blockVals
          pos += 1
          var bodyOut = ""
          e.indent += 1
          let saved = e.output
          e.output = ""
          e.emitBody(bodyBlock, asReturn = true)
          bodyOut = e.output
          e.output = saved
          e.indent -= 1
          result = "(function()\n" & e.pad & "  if " & cond & " then\n" &
                   bodyOut &
                   e.pad & "  end\n" & e.pad & "end)()"
        else:
          result = "nil"

      # --- either: condition true-block false-block ---
      elif name == "either":
        let cond = e.emitExpr(vals, pos)
        var trueBlock: seq[KtgValue] = @[]
        var falseBlock: seq[KtgValue] = @[]
        if pos < vals.len and vals[pos].kind == vkBlock:
          trueBlock = vals[pos].blockVals
          pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock:
          falseBlock = vals[pos].blockVals
          pos += 1
        result = e.emitEitherExpr(cond, trueBlock, falseBlock)

      # --- function definition ---
      elif name == "function":
        if pos + 1 < vals.len and vals[pos].kind == vkBlock and vals[pos + 1].kind == vkBlock:
          let specBlock = vals[pos].blockVals
          let bodyBlock = vals[pos + 1].blockVals
          pos += 2
          let saved = e.output
          e.output = ""
          result = e.emitFuncDef(specBlock, bodyBlock)
          e.output = saved
        else:
          result = "nil"

      elif name == "does":
        if pos < vals.len and vals[pos].kind == vkBlock:
          let bodyBlock = vals[pos].blockVals
          pos += 1
          let saved = e.output
          e.output = ""
          result = e.emitFuncDef(@[], bodyBlock)
          e.output = saved
        else:
          result = "nil"

      # --- context: block -> Lua table ---
      elif name == "context":
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          result = e.emitContextBlock(blk)
        else:
          result = "{}"

      # --- scope: lexical scope block ---
      elif name == "scope":
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          let saved = e.output
          e.output = ""
          e.indent += 1
          e.emitBlock(blk, asReturn = true)
          let bodyStr = e.output
          e.output = saved
          e.indent -= 1
          result = "(function()\n" & bodyStr & e.pad & "end)()"
        else:
          result = "nil"

      # --- loop dialect ---
      elif name == "loop":
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          let saved = e.output
          e.output = ""
          discard e.emitLoop(blk)
          let loopCode = e.output
          e.output = saved
          e.raw(loopCode)
          result = "nil"
        else:
          result = "nil"

      # --- attempt dialect ---
      elif name == "attempt":
        if pos < vals.len and vals[pos].kind == vkBlock:
          let pipelineBlk = vals[pos].blockVals
          pos += 1
          result = e.emitAttemptExpr(pipelineBlk)
        else:
          result = "nil"

      # --- capture: declarative keyword extraction ---
      elif name == "capture":
        # Parse schema (second arg) at compile time to get keyword names
        let dataStart = pos
        # Skip first arg to peek at schema
        var schemaPos = pos
        discard e.emitExpr(vals, schemaPos)  # skip data arg
        var keywords: seq[string] = @[]
        var specs: seq[(string, int)] = @[]  # (keyword, exact) where -1 = greedy
        if schemaPos < vals.len and vals[schemaPos].kind == vkBlock:
          for s in vals[schemaPos].blockVals:
            if s.kind == vkWord and s.wordKind == wkMetaWord:
              let parts = s.wordName.split('/')
              var keyword = s.wordName
              var exact = -1
              if parts.len >= 2:
                var allDigits = true
                for c in parts[^1]:
                  if c notin {'0'..'9'}: allDigits = false; break
                if allDigits and parts[^1].len > 0:
                  exact = parseInt(parts[^1])
                  keyword = parts[0 .. ^2].join("/")
              keywords.add(keyword)
              specs.add((keyword, exact))
        # Now emit the data block with keyword-matching words as strings
        pos = dataStart
        if pos < vals.len and vals[pos].kind == vkBlock:
          let dataBlock = vals[pos].blockVals
          pos += 1
          var dataParts: seq[string] = @[]
          var dpos = 0
          while dpos < dataBlock.len:
            let dval = dataBlock[dpos]
            if dval.kind == vkWord and dval.wordKind == wkWord and dval.wordName in keywords:
              dataParts.add("\"" & dval.wordName & "\"")
              dpos += 1
            else:
              dataParts.add(e.emitExpr(dataBlock, dpos))
          let dataStr = "{" & dataParts.join(", ") & "}"
          # Emit specs table
          var specParts: seq[string] = @[]
          for (kw, exact) in specs:
            if exact >= 0:
              specParts.add("{\"" & kw & "\", " & $exact & "}")
            else:
              specParts.add("\"" & kw & "\"")
          let specStr = "{" & specParts.join(", ") & "}"
          # Skip the schema block
          if pos < vals.len and vals[pos].kind == vkBlock:
            pos += 1
          e.useHelper("_capture")
          result = "_capture(" & dataStr & ", " & specStr & ")"
        else:
          # Data is a variable — can't rewrite keywords
          let dataExpr = e.emitExpr(vals, pos)
          if pos < vals.len and vals[pos].kind == vkBlock:
            var specParts: seq[string] = @[]
            for (kw, exact) in specs:
              if exact >= 0:
                specParts.add("{\"" & kw & "\", " & $exact & "}")
              else:
                specParts.add("\"" & kw & "\"")
            pos += 1
            e.useHelper("_capture")
            result = "_capture(" & dataExpr & ", {" & specParts.join(", ") & "})"
          else:
            result = "nil"

      # --- match dialect ---
      elif name == "match":
        let valueExpr = e.emitExpr(vals, pos)
        if pos < vals.len and vals[pos].kind == vkBlock:
          let rulesBlock = vals[pos].blockVals
          pos += 1
          # match in expression context -> returns a value
          result = e.emitMatchExpr(valueExpr, rulesBlock)
        else:
          result = "nil"

      # --- String operations ---
      elif name == "join":
        let a = e.emitExpr(vals, pos)
        let b = e.emitExpr(vals, pos)
        result = "tostring(" & a & ") .. tostring(" & b & ")"

      elif name == "rejoin":
        # rejoin on a block — build a table.concat with tostring on each element
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          var parts: seq[string] = @[]
          var bpos = 0
          while bpos < blk.len:
            let elem = e.emitExpr(blk, bpos)
            # Strings don't need tostring, everything else does
            if elem.startsWith("\""):
              parts.add(elem)
            else:
              parts.add("tostring(" & elem & ")")
          result = "table.concat({" & parts.join(", ") & "})"
        else:
          let arg = e.emitExpr(vals, pos)
          result = "table.concat(" & arg & ")"

      elif name == "trim":
        let arg = e.emitExpr(vals, pos)
        result = arg & ":match(\"^%s*(.-)%s*$\")"

      elif name == "uppercase":
        let arg = e.emitExpr(vals, pos)
        result = "string.upper(" & arg & ")"

      elif name == "lowercase":
        let arg = e.emitExpr(vals, pos)
        result = "string.lower(" & arg & ")"

      elif name == "split":
        let str = e.emitExpr(vals, pos)
        let delim = e.emitExpr(vals, pos)
        result = "(function()" &
                 " local r,s,d={}, " & str & ", " & delim &
                 "; for m in (s..d):gmatch(\"(.-)\"..d) do r[#r+1]=m end" &
                 "; return r end)()"

      elif name == "replace":
        let str = e.emitExpr(vals, pos)
        let old = e.emitExpr(vals, pos)
        let new_str = e.emitExpr(vals, pos)
        result = "string.gsub(" & str & ", " & old & ", " & new_str & ")"

      # --- Series operations ---
      elif name in ["size?", "length?"]:
        let arg = e.emitExpr(vals, pos)
        result = "#" & arg

      elif name == "empty?":
        let arg = e.emitExpr(vals, pos)
        result = "(#" & arg & " == 0)"

      elif name == "first":
        let arg = e.emitExpr(vals, pos)
        result = arg & "[1]"

      elif name == "second":
        let arg = e.emitExpr(vals, pos)
        result = arg & "[2]"

      elif name == "last":
        let arg = e.emitExpr(vals, pos)
        result = arg & "[#" & arg & "]"

      elif name == "pick":
        let blk = e.emitExpr(vals, pos)
        let idx = e.emitExpr(vals, pos)
        result = blk & "[" & idx & "]"

      elif name == "append":
        let blk = e.emitExpr(vals, pos)
        let val_expr = e.emitExpr(vals, pos)
        e.useHelper("_append")
        result = "_append(" & blk & ", " & val_expr & ")"

      elif name == "append/only":
        let blk = e.emitExpr(vals, pos)
        let val_expr = e.emitExpr(vals, pos)
        result = "(function() table.insert(" & blk & ", " & val_expr & "); return " & blk & " end)()"

      elif name == "copy":
        let arg = e.emitExpr(vals, pos)
        result = "(function() local r={}; for i,v in ipairs(" & arg & ") do r[i]=v end; return r end)()"

      elif name == "insert":
        let blk = e.emitExpr(vals, pos)
        let val_expr = e.emitExpr(vals, pos)
        let idx_expr = e.emitExpr(vals, pos)
        result = "(function() table.insert(" & blk & ", " & idx_expr & ", " & val_expr & "); return " & blk & " end)()"

      elif name == "remove":
        let blk = e.emitExpr(vals, pos)
        let idx_expr = e.emitExpr(vals, pos)
        result = "(function() table.remove(" & blk & ", " & idx_expr & "); return " & blk & " end)()"

      elif name == "select":
        let blk = e.emitExpr(vals, pos)
        let key = e.emitExpr(vals, pos)
        result = blk & "[" & key & "]"

      elif name == "has?":
        let blk = e.emitExpr(vals, pos)
        let val_expr = e.emitExpr(vals, pos)
        result = "(" & blk & "[" & val_expr & "] ~= nil)"

      elif name == "find":
        let series = e.emitExpr(vals, pos)
        let needle = e.emitExpr(vals, pos)
        # Works for both strings (string.find) and tables (linear scan)
        result = "(function() " &
                 "if type(" & series & ") == \"string\" then " &
                 "local i = string.find(" & series & ", " & needle & ", 1, true); " &
                 "if i then return i end; return nil " &
                 "else " &
                 "for i, v in ipairs(" & series & ") do if v == " & needle & " then return i end end; return nil " &
                 "end " &
                 "end)()"

      elif name == "reverse":
        let arg = e.emitExpr(vals, pos)
        result = "(function() " &
                 "if type(" & arg & ") == \"string\" then return string.reverse(" & arg & ") " &
                 "else local r={}; for i=#" & arg & ",1,-1 do r[#r+1]=" & arg & "[i] end; return r end " &
                 "end)()"

      elif name == "byte":
        let arg = e.emitExpr(vals, pos)
        result = "string.byte(" & arg & ", 1)"

      elif name == "char":
        let arg = e.emitExpr(vals, pos)
        result = "string.char(" & arg & ")"

      elif name == "starts-with?":
        let str = e.emitExpr(vals, pos)
        let prefix = e.emitExpr(vals, pos)
        result = "(string.sub(" & str & ", 1, #" & prefix & ") == " & prefix & ")"

      elif name == "ends-with?":
        let str = e.emitExpr(vals, pos)
        let suffix = e.emitExpr(vals, pos)
        result = "(string.sub(" & str & ", -#" & suffix & ") == " & suffix & ")"

      elif name == "substring":
        let str = e.emitExpr(vals, pos)
        let start = e.emitExpr(vals, pos)
        let length = e.emitExpr(vals, pos)
        result = "string.sub(" & str & ", " & start & ", " & start & " + " & length & " - 1)"

      # --- Type predicates (none?, integer?, etc.) ---
      elif isTypePredicate(name):
        let arg = e.emitExpr(vals, pos)
        result = e.emitTypePredicateCall(name, arg)

      # --- Math ---
      elif name == "abs":
        let arg = e.emitExpr(vals, pos)
        result = "math.abs(" & arg & ")"

      elif name == "negate":
        let arg = e.emitExpr(vals, pos)
        result = "-(" & arg & ")"

      elif name == "min":
        let a = e.emitExpr(vals, pos)
        let b = e.emitExpr(vals, pos)
        result = "math.min(" & a & ", " & b & ")"

      elif name == "max":
        let a = e.emitExpr(vals, pos)
        let b = e.emitExpr(vals, pos)
        result = "math.max(" & a & ", " & b & ")"

      elif name == "round":
        let arg = e.emitExpr(vals, pos)
        result = "math.floor(" & arg & " + 0.5)"
      elif name == "odd?":
        let arg = e.emitExpr(vals, pos)
        result = "(" & arg & " % 2 ~= 0)"

      elif name == "even?":
        let arg = e.emitExpr(vals, pos)
        result = "(" & arg & " % 2 == 0)"

      elif name == "sqrt":
        let arg = e.emitExpr(vals, pos)
        result = "math.sqrt(" & arg & ")"

      elif name == "sin":
        result = "math.sin(" & e.emitExpr(vals, pos) & ")"
      elif name == "cos":
        result = "math.cos(" & e.emitExpr(vals, pos) & ")"
      elif name == "tan":
        result = "math.tan(" & e.emitExpr(vals, pos) & ")"
      elif name == "asin":
        result = "math.asin(" & e.emitExpr(vals, pos) & ")"
      elif name == "acos":
        result = "math.acos(" & e.emitExpr(vals, pos) & ")"
      elif name == "atan2":
        let y = e.emitExpr(vals, pos)
        let x = e.emitExpr(vals, pos)
        result = "math.atan2(" & y & ", " & x & ")"
      elif name == "pow":
        let base = e.emitExpr(vals, pos)
        let exp = e.emitExpr(vals, pos)
        result = "math.pow(" & base & ", " & exp & ")"
      elif name == "exp":
        result = "math.exp(" & e.emitExpr(vals, pos) & ")"
      elif name == "log":
        result = "math.log(" & e.emitExpr(vals, pos) & ")"
      elif name == "log10":
        result = "math.log10(" & e.emitExpr(vals, pos) & ")"
      elif name == "to-degrees":
        result = "math.deg(" & e.emitExpr(vals, pos) & ")"
      elif name == "to-radians":
        result = "math.rad(" & e.emitExpr(vals, pos) & ")"
      elif name == "floor":
        result = "math.floor(" & e.emitExpr(vals, pos) & ")"
      elif name == "ceil":
        result = "math.ceil(" & e.emitExpr(vals, pos) & ")"
      elif name == "pi":
        result = "math.pi"

      elif name == "random":
        result = "math.random() * " & e.emitExpr(vals, pos)

      # --- Type conversion ---
      elif name == "to":
        let typeExpr = e.emitExpr(vals, pos)
        let val_expr = e.emitExpr(vals, pos)
        # Best-effort type conversion based on target type
        if typeExpr == "\"string!\"":
          result = "tostring(" & val_expr & ")"
        elif typeExpr == "\"integer!\"":
          result = "math.floor(tonumber(" & val_expr & "))"
        elif typeExpr == "\"float!\"":
          result = "tonumber(" & val_expr & ")"
        else:
          result = "tonumber(" & val_expr & ") or " & val_expr

      # --- Type introspection (erased — emit as string for now) ---
      elif name == "type":
        let arg = e.emitExpr(vals, pos)
        result = "type(" & arg & ")"

      # --- sort ---
      elif name == "sort":
        let arg = e.emitExpr(vals, pos)
        result = "(function() table.sort(" & arg & "); return " & arg & " end)()"

      # --- try ---
      elif name == "try":
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          let saved = e.output
          e.output = ""
          e.indent += 1
          e.emitBody(blk, asReturn = true)
          let bodyStr = e.output
          e.output = saved
          e.indent -= 1
          result = "(function()\n" &
                   e.pad & "  local ok, result = pcall(function()\n" &
                   bodyStr &
                   e.pad & "  end)\n" &
                   e.pad & "  if ok then return {ok=true, value=result}\n" &
                   e.pad & "  else return {ok=false, message=result} end\n" &
                   e.pad & "end)()"
        else:
          result = "nil"

      # --- apply ---
      elif name == "apply":
        let fn = e.emitExpr(vals, pos)
        let args_expr = e.emitExpr(vals, pos)
        result = fn & "(unpack(" & args_expr & "))"

      # --- reduce ---
      elif name == "reduce":
        let arg = e.emitExpr(vals, pos)
        result = arg

      # --- require: compile dependency and emit Lua require() ---
      elif name == "import":
        if pos < vals.len:
          let pathVal = vals[pos]
          pos += 1
          var rawPath = case pathVal.kind
            of vkFile: pathVal.filePath
            of vkString: pathVal.strVal
            else: $pathVal
          # Resolve to absolute path for cycle detection
          let srcDir = if e.sourceDir.len > 0: e.sourceDir else: getCurrentDir()
          let absPath = if rawPath.isAbsolute: rawPath else: srcDir / rawPath
          # Cycle detection
          if absPath in e.compiling:
            raise EmitError(msg: "circular require detected: " & rawPath)
          # Compute Lua module name (filename without extension)
          let moduleName = rawPath.changeFileExt("").replace("/", ".").replace("\\", ".")
          # Compile the required file
          if fileExists(absPath):
            let depSource = readFile(absPath)
            var depAst = parseSource(depSource)
            # Strip Kintsugi header
            if depAst.len >= 2 and depAst[0].kind == vkWord and depAst[0].wordKind == wkWord and
               depAst[0].wordName.startsWith("Kintsugi") and depAst[1].kind == vkBlock:
              depAst = depAst[2..^1]
            let outPath = absPath.changeFileExt("lua")
            # Add this file to compiling set for cycle detection
            var childCompiling = e.compiling
            childCompiling.incl(absPath)
            let depDir = parentDir(absPath)
            let depLua = emitLuaModule(depAst, depDir, childCompiling)
            writeFile(outPath, depLua)
          result = "require(\"" & moduleName & "\")"
        else:
          result = "nil"

      # --- exports: handled at module level, skip in expression context ---
      elif name == "exports":
        discard e.emitExpr(vals, pos)  # consume the block arg
        result = "nil"

      # --- Generic function call or variable reference ---
      else:
        let resolvedLua = e.resolvedName(name)
        let info = e.getBinding(name)
        let a = e.arity(name)
        if a >= 0:
          var args: seq[string] = @[]
          for i in 0 ..< a:
            args.add(e.emitExpr(vals, pos))
          # Append default refinement args (all false/nil) for non-refinement calls
          if info.refinements.len > 0:
            for r in info.refinements:
              args.add("false")
              for j in 0 ..< r.paramCount:
                args.add("nil")
          result = resolvedLua & "(" & args.join(", ") & ")"
        else:
          result = resolvedLua

  # --- Types, files, urls, emails — emit as string literals ---
  of vkType:
    result = "\"" & val.typeName & "\""
  of vkFile:
    result = "\"" & luaEscape(val.filePath) & "\""
  of vkUrl:
    result = "\"" & luaEscape(val.urlVal) & "\""
  of vkEmail:
    result = "\"" & luaEscape(val.emailVal) & "\""

  # --- Date/Time — emit as tables ---
  of vkDate:
    result = "{year=" & $val.year & ", month=" & $val.month & ", day=" & $val.day & "}"
  of vkTime:
    result = "{hour=" & $val.hour & ", minute=" & $val.minute & ", second=" & $val.second & "}"

  # --- Remaining types ---
  of vkMap:
    var parts: seq[string] = @[]
    for k, v in val.mapEntries:
      parts.add(luaName(k) & " = " & emitLiteral(v))
    result = "{" & parts.join(", ") & "}"

  of vkSet:
    var parts: seq[string] = @[]
    for m in val.setMembers:
      parts.add("[\"" & luaEscape(m) & "\"] = true")
    result = "{" & parts.join(", ") & "}"

  of vkContext:
    var parts: seq[string] = @[]
    for k, v in val.ctx.entries:
      parts.add(luaName(k) & " = " & emitLiteral(v))
    result = "{" & parts.join(", ") & "}"

  of vkObject:
    var parts: seq[string] = @[]
    for k, v in val.obj.entries:
      parts.add(luaName(k) & " = " & emitLiteral(v))
    result = "{" & parts.join(", ") & "}"

  of vkFunction, vkNative:
    result = "nil  -- cannot emit runtime function/native value"

  # Handle infix chain
  while pos < vals.len and isInfixOp(vals[pos]):
    let op = vals[pos]
    let opStr = if op.kind == vkOp: luaOp(op.opSymbol) else: luaOp(op.wordName)
    pos += 1
    let right = e.emitExpr(vals, pos)
    # Special case: = none / <> none → _is_none() / not _is_none()
    if right == "nil" and opStr == "==":
      e.useHelper("_is_none")
      result = "_is_none(" & result & ")"
    elif right == "nil" and opStr == "~=":
      e.useHelper("_is_none")
      result = "not _is_none(" & result & ")"
    elif result == "nil" and opStr == "==":
      e.useHelper("_is_none")
      result = "_is_none(" & right & ")"
    elif result == "nil" and opStr == "~=":
      e.useHelper("_is_none")
      result = "not _is_none(" & right & ")"
    else:
      result = result & " " & opStr & " " & right

proc emitExprWithChain(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  ## Like emitExpr but also processes -> method chains.
  result = e.emitExpr(vals, pos)
  while pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordName == "->":
    pos += 1  # skip ->
    if pos >= vals.len or vals[pos].kind != vkWord:
      break
    let methodName = luaName(vals[pos].wordName)
    pos += 1
    var args: seq[string] = @[]
    while pos < vals.len:
      let next = vals[pos]
      if next.kind == vkWord and next.wordName == "->": break
      if isInfixOp(next): break
      if next.kind == vkWord and next.wordKind == wkSetWord: break
      if next.kind == vkWord and next.wordKind == wkMetaWord: break
      if next.kind == vkWord and next.wordKind == wkWord and
         next.wordName in ["if", "either", "unless", "loop", "match",
                            "print", "return", "break", "error", "try"]: break
      if next.kind == vkWord and next.wordKind == wkWord and next.wordName.contains('/'): break
      if next.kind == vkBlock: break
      if next.kind == vkWord and next.wordKind == wkWord and
         pos + 1 < vals.len and vals[pos + 1].kind == vkWord and vals[pos + 1].wordName == "->":
        break
      args.add(e.emitExpr(vals, pos))
    result = result & ":" & methodName & "(" & args.join(", ") & ")"

# ---------------------------------------------------------------------------
# Emit a sequence of values as Lua statements
# ---------------------------------------------------------------------------

proc findLastStmtStart(e: var LuaEmitter, vals: seq[KtgValue]): int =
  ## Dry-run through vals to find where the last statement starts.
  ## Uses emitExpr with output discarded to correctly advance position.
  var stmtStarts: seq[int] = @[]
  var pos = 0
  let saved = e.output
  e.output = ""
  while pos < vals.len:
    stmtStarts.add(pos)
    let val = vals[pos]
    # Skip headers, bindings, exports
    if val.kind == vkWord and val.wordKind == wkWord and
       val.wordName.startsWith("Kintsugi"):
      pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
      continue
    if val.kind == vkWord and val.wordKind == wkWord and
       val.wordName in ["bindings", "exports"]:
      pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
      continue
    # @const prefix
    if val.kind == vkWord and val.wordKind == wkMetaWord and val.wordName == "const":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkSetWord:
        pos += 1
        discard e.emitExprWithChain(vals, pos)
        continue
      continue
    # @global prefix
    if val.kind == vkWord and val.wordKind == wkMetaWord and val.wordName == "global":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkSetWord:
        pos += 1
        discard e.emitExprWithChain(vals, pos)
        continue
      continue
    # Set-word
    if val.kind == vkWord and val.wordKind == wkSetWord:
      pos += 1
      discard e.emitExprWithChain(vals, pos)
      continue
    # Keywords with known token counts
    if val.kind == vkWord and val.wordKind == wkWord:
      case val.wordName
      of "if", "unless":
        pos += 1
        discard e.emitExpr(vals, pos)
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
        continue
      of "either":
        pos += 1
        discard e.emitExpr(vals, pos)
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
        continue
      of "loop", "scope":
        pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
        continue
      of "match":
        pos += 1
        discard e.emitExpr(vals, pos)
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
        continue
      of "return":
        pos += 1
        discard e.emitExpr(vals, pos)
        continue
      of "break":
        pos += 1
        continue
      of "print", "assert":
        pos += 1
        discard e.emitExpr(vals, pos)
        continue
      of "raw":
        pos += 1
        discard e.emitExpr(vals, pos)
        continue
      of "set":
        pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
        discard e.emitExpr(vals, pos)
        continue
      of "remove":
        pos += 1
        discard e.emitExpr(vals, pos)
        discard e.emitExpr(vals, pos)
        continue
      of "insert":
        pos += 1
        discard e.emitExpr(vals, pos)
        discard e.emitExpr(vals, pos)
        discard e.emitExpr(vals, pos)
        continue
      of "append":
        pos += 1
        discard e.emitExpr(vals, pos)
        discard e.emitExpr(vals, pos)
        continue
      else: discard
      # Loop refinement paths (loop/collect, loop/fold, loop/partition)
      if val.wordName.startsWith("loop/"):
        pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
        continue
    # Generic expression
    discard e.emitExprWithChain(vals, pos)
  e.output = saved
  if stmtStarts.len > 0: stmtStarts[^1] else: 0

proc emitLastWithReturn(e: var LuaEmitter, vals: seq[KtgValue]) =
  ## Emit the last statement of a block with implicit return.
  if vals.len == 0: return

  let lastVal = vals[0]

  # return/break already emit themselves
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName in ["return", "break"]:
    e.emitBlock(vals)
    return

  # set-word: emit assignment, then return the variable
  if lastVal.kind == vkWord and lastVal.wordKind == wkSetWord:
    e.emitBlock(vals)
    let name = if lastVal.wordName.contains('/'):
                 emitPath(lastVal.wordName)
               else:
                 luaName(lastVal.wordName)
    e.ln("return " & name)
    return

  # if/unless: emit with return inside body
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName in ["if", "unless"]:
    var lpos = 1
    let cond = e.emitExpr(vals, lpos)
    if lpos < vals.len and vals[lpos].kind == vkBlock:
      let body = vals[lpos].blockVals
      if lastVal.wordName == "unless":
        e.ln("if not (" & cond & ") then")
      else:
        e.ln("if " & cond & " then")
      e.indent += 1
      e.emitBlock(body, asReturn = true)
      e.indent -= 1
      e.ln("end")
      return

  # either: return in both branches
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName == "either":
    var lpos = 1
    let cond = e.emitExpr(vals, lpos)
    var trueBlock: seq[KtgValue] = @[]
    var falseBlock: seq[KtgValue] = @[]
    if lpos < vals.len and vals[lpos].kind == vkBlock:
      trueBlock = vals[lpos].blockVals
      lpos += 1
    if lpos < vals.len and vals[lpos].kind == vkBlock:
      falseBlock = vals[lpos].blockVals
    e.ln("if " & cond & " then")
    e.indent += 1
    e.emitBlock(trueBlock, asReturn = true)
    e.indent -= 1
    e.ln("else")
    e.indent += 1
    e.emitBlock(falseBlock, asReturn = true)
    e.indent -= 1
    e.ln("end")
    return

  # match: return in handlers
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName == "match":
    var lpos = 1
    let valueExpr = e.emitExpr(vals, lpos)
    if lpos < vals.len and vals[lpos].kind == vkBlock:
      let rulesBlock = vals[lpos].blockVals
      e.emitMatchStmt(valueExpr, rulesBlock, asReturn = true)
      return

  # loop, print: no return value
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName in ["loop", "print"]:
    e.emitBlock(vals)
    return

  # loop refinements: return the result
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName.startsWith("loop/"):
    let refinement = lastVal.wordName.split('/')[1]
    if vals.len > 1 and vals[1].kind == vkBlock:
      let resultVar = e.emitLoop(vals[1].blockVals, refinement)
      if resultVar.len > 0:
        e.ln("return " & resultVar)
      return

  # Generic expression: return it
  var lpos = 0
  let expr = e.emitExprWithChain(vals, lpos)
  if expr != "nil":
    e.ln("return " & expr)

proc emitBlock(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false) =
  ## Emit a block of values as statements. If asReturn, the last expression
  ## gets an implicit `return`.
  if vals.len == 0: return

  if asReturn:
    let lastStart = e.findLastStmtStart(vals)
    if lastStart > 0:
      e.emitBlock(vals[0 ..< lastStart])
    e.emitLastWithReturn(vals[lastStart .. ^1])
    return

  var pos = 0
  while pos < vals.len:
    let val = vals[pos]

    # --- raw: write string verbatim as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "raw":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkString:
        e.ln(vals[pos].strVal)
        pos += 1
      continue

    # --- Skip Kintsugi header (Kintsugi [...] or Kintsugi/Lua [...]) ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName.startsWith("Kintsugi"):
      pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock:
        pos += 1
      continue

    # --- Bindings block: emit alias declarations, skip the rest ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "bindings":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock:
        # Emit local declarations for 'alias bindings
        let blk = vals[pos].blockVals
        var bpos = 0
        while bpos < blk.len:
          if bpos >= blk.len: break
          let bname = blk[bpos]
          if bname.kind != vkWord or bname.wordKind != wkWord:
            bpos += 1
            continue
          let bnameName = bname.wordName
          bpos += 1
          if bpos >= blk.len: break
          let bpath = blk[bpos]
          if bpath.kind != vkString:
            bpos += 1
            continue
          let bpathStr = bpath.strVal
          bpos += 1
          if bpos >= blk.len: break
          let bkind = blk[bpos]
          if bkind.kind != vkWord or bkind.wordKind != wkLitWord:
            bpos += 1
            continue
          let bkindName = bkind.wordName
          bpos += 1
          if bkindName == "call" and bpos < blk.len and blk[bpos].kind == vkInteger:
            bpos += 1  # skip first arity
            if bpos < blk.len and blk[bpos].kind == vkInteger:
              bpos += 1  # skip second arity (max)
          if bkindName == "alias":
            e.ln("local " & luaName(bnameName) & " = " & bpathStr)
        pos += 1
      continue

    # --- set [names] value — destructuring assignment with @rest support ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "set":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock:
        let namesBlock = vals[pos].blockVals
        pos += 1
        let valueExpr = e.emitExpr(vals, pos)
        var names: seq[string] = @[]
        var restName = ""
        var restAfter = 0  # how many positional names before @rest
        for v in namesBlock:
          if v.kind == vkWord and v.wordKind == wkMetaWord:
            restName = luaName(v.wordName)
            restAfter = names.len
            e.locals.incl(restName)
          elif v.kind == vkWord and v.wordKind == wkWord:
            let n = luaName(v.wordName)
            names.add(n)
            e.locals.incl(n)
        let tmp = "_set_tmp"
        e.ln("local " & tmp & " = " & valueExpr)
        if names.len > 0:
          var indices: seq[string] = @[]
          for i in 1 .. names.len:
            indices.add(tmp & "[" & $i & "]")
          e.ln("local " & names.join(", ") & " = " & indices.join(", "))
        if restName.len > 0:
          # Collect remaining elements: {unpack(tmp, N+1)}
          e.ln("local " & restName & " = {unpack(" & tmp & ", " & $(restAfter + 1) & ")}")
        continue

    # --- Bound name as statement (e.g., update-sprites -> gfx.sprite.update()) ---
    if val.kind == vkWord and val.wordKind == wkWord and
       val.wordName in e.nameMap and val.wordName notin ["if", "either", "unless",
         "loop", "match", "print", "return", "break", "error", "try"] and
       not val.wordName.contains('/'):
      let name = val.wordName
      let resolvedLua = e.nameMap[name]
      let a = e.arity(name)
      pos += 1
      if name in e.bindingKinds and e.bindingKinds[name] == bkAssign:
        # assign binding: consume 1 arg and emit as assignment
        let arg = e.emitExpr(vals, pos)
        e.ln(resolvedLua & " = " & arg)
        continue
      elif a > 0:
        var args: seq[string] = @[]
        for i in 0 ..< a:
          args.add(e.emitExpr(vals, pos))
        e.ln(resolvedLua & "(" & args.join(", ") & ")")
        continue
      elif a == 0:
        e.ln(resolvedLua & "()")
        continue
      else:
        # const or alias — emit bare
        e.ln(resolvedLua)
        continue

    # --- @global prefix: @global x: value — emit without 'local' ---
    if val.kind == vkWord and val.wordKind == wkMetaWord and val.wordName == "global":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkSetWord:
        let rawName = vals[pos].wordName
        let name = luaName(rawName)
        pos += 1
        let expr = e.emitExprWithChain(vals, pos)
        e.ln(name & " = " & expr)  # no 'local' prefix — global
        continue
      # @global word or @global [words] — mark as global (no-op in compiled output)
      if pos < vals.len and vals[pos].kind == vkBlock:
        pos += 1  # skip the block
      elif pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord:
        pos += 1  # skip the word
      continue

    # --- @const prefix: @const x: value ---
    if val.kind == vkWord and val.wordKind == wkMetaWord and val.wordName == "const":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkSetWord:
        let rawName = vals[pos].wordName
        let name = luaName(rawName)
        pos += 1
        let prefix = if name in e.locals: "" else: "local "
        e.locals.incl(name)
        let expr = e.emitExprWithChain(vals, pos)
        e.ln(prefix & name & " <const> = " & expr)
        continue
      # @const without set-word — skip
      continue

    # --- Set-word at statement level ---
    if val.kind == vkWord and val.wordKind == wkSetWord:
      let rawName = val.wordName
      let isPath = rawName.contains('/')
      let isBound = rawName in e.nameMap
      let name = if isBound:
                   e.nameMap[rawName]
                 elif isPath:
                   emitPath(rawName)
                 else:
                   luaName(rawName)
      pos += 1

      let prefix = if isBound: ""            # bound names: global path, no 'local'
                   elif isPath: ""            # globals: no 'local'
                   elif name in e.locals: "" # already declared: no 'local'
                   else: "local "
      let constAnnotation = ""

      # Track this as a local declaration (unless it's a path)
      if not isPath:
        e.locals.incl(name)

      # Check if RHS is a function definition
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName == "function":
        pos += 1
        if pos + 1 < vals.len and vals[pos].kind == vkBlock and vals[pos + 1].kind == vkBlock:
          let specBlock = vals[pos].blockVals
          let bodyBlock = vals[pos + 1].blockVals
          pos += 2

          # Extract param names using shared spec parser
          let spec = parseSpec(specBlock)
          let params = spec.allLuaParams()

          let isOverride = rawName in e.bindingKinds and e.bindingKinds[rawName] == bkOverride
          if isOverride:
            e.ln("function " & name & "(" & params.join(", ") & ")")
          elif isPath or isBound:
            e.ln(name & " = function(" & params.join(", ") & ")")
          else:
            e.ln(prefix & "function " & name & "(" & params.join(", ") & ")")
          let savedLocals = e.locals
          e.locals = initHashSet[string]()
          for p in params:
            e.locals.incl(p)
          e.indent += 1
          e.emitBody(bodyBlock, asReturn = not (isPath or isBound or isOverride))
          e.indent -= 1
          e.locals = savedLocals
          e.ln("end")
          continue

      # Check if RHS is a does (zero-arg function)
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName == "does":
        pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock:
          let bodyBlock = vals[pos].blockVals
          pos += 1
          if isPath or isBound:
            e.ln(name & " = function()")
          else:
            e.ln(prefix & "function " & name & "()")
          let savedLocals = e.locals
          e.locals = initHashSet[string]()
          e.indent += 1
          e.emitBody(bodyBlock, asReturn = not (isPath or isBound))
          e.indent -= 1
          e.locals = savedLocals
          e.ln("end")
          continue

      # Check if RHS is a match expression
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName == "match":
        pos += 1
        let valueExpr = e.emitExpr(vals, pos)
        if pos < vals.len and vals[pos].kind == vkBlock:
          let rulesBlock = vals[pos].blockVals
          pos += 1
          let matchExpr = e.emitMatchExpr(valueExpr, rulesBlock)
          e.ln(prefix & name & " = " & matchExpr)
          continue

      # Check if RHS is an either expression
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName == "either":
        pos += 1
        let cond = e.emitExpr(vals, pos)
        var trueBlock: seq[KtgValue] = @[]
        var falseBlock: seq[KtgValue] = @[]
        if pos < vals.len and vals[pos].kind == vkBlock:
          trueBlock = vals[pos].blockVals
          pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock:
          falseBlock = vals[pos].blockVals
          pos += 1
        let eitherExpr = e.emitEitherExpr(cond, trueBlock, falseBlock)
        e.ln(prefix & name & " = " & eitherExpr)
        continue

      # Regular assignment (with -> chain support)
      let expr = e.emitExprWithChain(vals, pos)
      e.ln(prefix & name & constAnnotation & " = " & expr)
      continue

    # --- Control flow as statements ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "if":
      pos += 1
      let cond = e.emitExpr(vals, pos)
      if pos < vals.len and vals[pos].kind == vkBlock:
        let body = vals[pos].blockVals
        pos += 1
        e.ln("if " & cond & " then")
        e.indent += 1
        e.emitBlock(body)
        e.indent -= 1
        e.ln("end")
        continue

    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "either":
      pos += 1
      let cond = e.emitExpr(vals, pos)
      var trueBlock: seq[KtgValue] = @[]
      var falseBlock: seq[KtgValue] = @[]
      if pos < vals.len and vals[pos].kind == vkBlock:
        trueBlock = vals[pos].blockVals
        pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock:
        falseBlock = vals[pos].blockVals
        pos += 1
      e.ln("if " & cond & " then")
      e.indent += 1
      e.emitBlock(trueBlock)
      e.indent -= 1
      e.ln("else")
      e.indent += 1
      e.emitBlock(falseBlock)
      e.indent -= 1
      e.ln("end")
      continue

    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "unless":
      pos += 1
      let cond = e.emitExpr(vals, pos)
      if pos < vals.len and vals[pos].kind == vkBlock:
        let body = vals[pos].blockVals
        pos += 1
        e.ln("if not (" & cond & ") then")
        e.indent += 1
        e.emitBlock(body)
        e.indent -= 1
        e.ln("end")
        continue

    # --- return as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "return":
      pos += 1
      let expr = e.emitExpr(vals, pos)
      e.ln("return " & expr)
      continue

    # --- break as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "break":
      pos += 1
      e.ln("break")
      continue

    # --- scope as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "scope":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock:
        let blk = vals[pos].blockVals
        pos += 1
        e.ln("do")
        e.indent += 1
        e.emitBlock(blk)
        e.indent -= 1
        e.ln("end")
        continue

    # --- loop as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "loop":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock:
        let blk = vals[pos].blockVals
        pos += 1
        discard e.emitLoop(blk)
        continue

    # --- match as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "match":
      pos += 1
      let valueExpr = e.emitExpr(vals, pos)
      if pos < vals.len and vals[pos].kind == vkBlock:
        let rulesBlock = vals[pos].blockVals
        pos += 1
        e.emitMatchStmt(valueExpr, rulesBlock)
        continue

    # --- assert as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "assert":
      pos += 1
      let arg = e.emitExpr(vals, pos)
      e.ln("assert(" & arg & ")")
      continue

    # --- exports: skip (handled at module level via findExports) ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "exports":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock:
        pos += 1  # skip the block arg
      continue

    # --- print as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "print":
      pos += 1
      let arg = e.emitExpr(vals, pos)
      e.ln("print(" & arg & ")")
      continue

    # --- Path call as statement (e.g., love/graphics/setColor 1.0 0.0 0.0) ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName.contains('/'):
      let pathParts = val.wordName.split('/')
      let head = pathParts[0]
      let path = emitPath(val.wordName)
      let fullBinding = e.getBinding(val.wordName)
      let headBinding = e.getBinding(head)

      if fullBinding.isFunction and not fullBinding.isUnknown:
        # Whole path is a known binding (from bindings dialect)
        pos += 1
        var args: seq[string] = @[]
        for i in 0 ..< fullBinding.arity:
          args.add(e.emitExpr(vals, pos))
        # Apply -> chain if present
        var result = path & "(" & args.join(", ") & ")"
        while pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordName == "->":
          pos += 1
          if pos >= vals.len or vals[pos].kind != vkWord: break
          let methodName = luaName(vals[pos].wordName)
          pos += 1
          var margs: seq[string] = @[]
          while pos < vals.len:
            let mn = vals[pos]
            if mn.kind == vkWord and mn.wordName == "->": break
            if isInfixOp(mn): break
            if mn.kind == vkWord and mn.wordKind == wkSetWord: break
            if mn.kind == vkBlock: break
            margs.add(e.emitExpr(vals, pos))
          result = result & ":" & methodName & "(" & margs.join(", ") & ")"
        e.ln(result)
        continue
      elif headBinding.isFunction and not headBinding.isUnknown:
        # Head is a known function — refinement call as statement
        let refNames = pathParts[1..^1]
        pos += 1
        var args: seq[string] = @[]
        for i in 0 ..< headBinding.arity:
          args.add(e.emitExpr(vals, pos))
        # Append refinement flags and params
        if headBinding.refinements.len > 0:
          for r in headBinding.refinements:
            let active = r.name in refNames
            args.add(if active: "true" else: "false")
            if active:
              for j in 0 ..< r.paramCount:
                args.add(e.emitExpr(vals, pos))
            else:
              for j in 0 ..< r.paramCount:
                args.add("nil")
        e.ln(e.resolvedName(head) & "(" & args.join(", ") & ")")
        continue
      else:
        # Value path or unknown — just emit as expression statement
        pos += 1
        e.ln(path)
        continue

    # --- Mutating series operations as statements ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "remove":
      pos += 1
      let blk = e.emitExpr(vals, pos)
      let idx = e.emitExpr(vals, pos)
      e.ln("table.remove(" & blk & ", " & idx & ")")
      continue

    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "insert":
      pos += 1
      let blk = e.emitExpr(vals, pos)
      let val_expr = e.emitExpr(vals, pos)
      let idx = e.emitExpr(vals, pos)
      e.ln("table.insert(" & blk & ", " & idx & ", " & val_expr & ")")
      continue

    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "append":
      pos += 1
      let blk = e.emitExpr(vals, pos)
      let val_expr = e.emitExpr(vals, pos)
      e.useHelper("_append")
      e.ln("_append(" & blk & ", " & val_expr & ")")
      continue

    # --- Generic expression as statement (with -> chain support) ---
    let expr = e.emitExprWithChain(vals, pos)
    if expr.len > 0 and expr != "nil":
      # In Lua, a statement starting with ( is ambiguous (could be function call
      # on previous expression). Prefix with ; to disambiguate.
      if expr.startsWith("("):
        e.ln(";" & expr)
      else:
        e.ln(expr)

proc emitBody(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false) =
  ## Emit a function body. Delegates to emitBlock.
  e.emitBlock(vals, asReturn)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

const PreludeUnpack = "local unpack = unpack or table.unpack\n"

const PreludeNone = """local _NONE = setmetatable({}, {__tostring = function() return "none" end})
local function _is_none(v) return v == nil or v == _NONE end
"""

const PreludeDeepCopy = """local function _deep_copy(t)
  if type(t) ~= "table" then return t end
  local r = {}; for k, v in pairs(t) do r[k] = _deep_copy(v) end; return r
end
"""


const PreludeCapture = """local function _capture(data, specs)
  local keywords, spec_map = {}, {}
  for _, s in ipairs(specs) do
    local name, exact = s, -1
    if type(s) == "table" then name, exact = s[1], s[2] end
    keywords[name] = true
    spec_map[name] = exact
  end
  local result, i = {}, 1
  while i <= #data do
    local val = data[i]
    if type(val) == "string" and spec_map[val] ~= nil then
      local name, exact = val, spec_map[val]
      i = i + 1
      if exact >= 0 then
        local cap = {}
        for j = 1, exact do if i <= #data then cap[#cap+1] = data[i]; i = i + 1 end end
        if result[name] == nil then
          if #cap == 1 then result[name] = cap[1] else result[name] = cap end
        else
          if type(result[name]) ~= "table" then result[name] = {result[name]} end
          for _, v in ipairs(cap) do result[name][#result[name]+1] = v end
        end
      else
        local cap = {}
        while i <= #data do
          local cur = data[i]
          if type(cur) == "string" and keywords[cur] and cur ~= name then break end
          if type(cur) == "string" and cur == name then i = i + 1
          else cap[#cap+1] = cur; i = i + 1 end
        end
        if #cap == 1 then result[name] = cap[1] elseif #cap > 1 then result[name] = cap end
      end
    else i = i + 1 end
  end
  return result
end
"""

const PreludeAppend = """local function _append(t, v)
  if type(v) == "table" then
    for i = 1, #v do t[#t+1] = v[i] end
  else
    t[#t+1] = v
  end
  return t
end
"""

proc buildPrelude(e: LuaEmitter): string =
  if e.usedHelpers.len == 0: return ""
  result = "-- Kintsugi runtime support\n"
  result &= PreludeUnpack
  if "_NONE" in e.usedHelpers or "_is_none" in e.usedHelpers:
    result &= PreludeNone
  if "_deep_copy" in e.usedHelpers:
    result &= PreludeDeepCopy
  if "_capture" in e.usedHelpers:
    result &= PreludeCapture
  if "_append" in e.usedHelpers:
    result &= PreludeAppend

proc prescanBindings(e: var LuaEmitter, blk: seq[KtgValue]) =
  ## Parse a bindings block and populate nameMap, arities, and bindingKinds.
  var pos = 0
  while pos < blk.len:
    # Expect: name (word) luaPath (string) kind (lit-word) [arity (integer)]
    if pos >= blk.len: break
    let nameVal = blk[pos]
    if nameVal.kind != vkWord or nameVal.wordKind != wkWord:
      pos += 1
      continue
    let name = nameVal.wordName
    pos += 1

    if pos >= blk.len: break
    let pathVal = blk[pos]
    if pathVal.kind != vkString:
      pos += 1
      continue
    let luaPath = pathVal.strVal
    pos += 1

    if pos >= blk.len: break
    let kindVal = blk[pos]
    if kindVal.kind != vkWord or kindVal.wordKind != wkLitWord:
      pos += 1
      continue
    let kindName = kindVal.wordName
    pos += 1

    case kindName
    of "call":
      e.nameMap[name] = luaPath
      e.bindingKinds[name] = bkCall
      # Fixed arity: single integer N
      if pos < blk.len and blk[pos].kind == vkInteger:
        let arity = int(blk[pos].intVal)
        pos += 1
        # Skip legacy second integer (variadic max) if present
        if pos < blk.len and blk[pos].kind == vkInteger:
          pos += 1
        e.bindings[name] = BindingInfo(arity: arity, isFunction: true, isUnknown: false)
      else:
        e.bindings[name] = BindingInfo(arity: 0, isFunction: true, isUnknown: false)
    of "const":
      e.nameMap[name] = luaPath
      e.bindings[name] = BindingInfo(arity: -1, isFunction: false, isUnknown: false)
      e.bindingKinds[name] = bkConst
    of "alias":
      # Alias emits a local declaration; no nameMap entry needed since
      # the local variable name matches the Kintsugi name via luaName.
      e.bindingKinds[name] = bkAlias
    of "assign":
      e.nameMap[name] = luaPath
      e.bindings[name] = BindingInfo(arity: 1, isFunction: true, isUnknown: false)
      e.bindingKinds[name] = bkAssign
    of "override":
      e.nameMap[name] = luaPath
      e.bindingKinds[name] = bkOverride
    else:
      discard

proc prescanBlock(e: var LuaEmitter, vals: seq[KtgValue]) =
  ## Recursively scan a block for function definitions and value bindings.
  var i = 0
  while i < vals.len:
    # bindings [...] dialect
    if vals[i].kind == vkWord and vals[i].wordKind == wkWord and
       vals[i].wordName == "bindings":
      if i + 1 < vals.len and vals[i + 1].kind == vkBlock:
        e.prescanBindings(vals[i + 1].blockVals)
        i += 2
        continue

    # name: function [spec] [body]
    if vals[i].kind == vkWord and vals[i].wordKind == wkSetWord:
      let name = vals[i].wordName
      if i + 1 < vals.len and vals[i + 1].kind == vkWord and
         vals[i + 1].wordKind == wkWord and vals[i + 1].wordName == "function":
        if i + 2 < vals.len and vals[i + 2].kind == vkBlock:
          let spec = vals[i + 2].blockVals
          var paramCount = 0
          var refInfos: seq[RefinementInfo] = @[]
          var inRefinement = false
          var j = 0
          while j < spec.len:
            let s = spec[j]
            # Refinement: /name token
            if s.kind == vkWord and s.wordKind == wkWord and s.wordName.startsWith("/"):
              let refName = s.wordName[1..^1]
              refInfos.add(RefinementInfo(name: refName, paramCount: 0))
              inRefinement = true
              j += 1
              continue
            # Count params
            if s.kind == vkWord and s.wordKind == wkWord:
              if inRefinement:
                refInfos[^1].paramCount += 1
              else:
                paramCount += 1
            elif s.kind == vkWord and s.wordKind == wkSetWord:
              # return: [type] — skip
              j += 1
              if j < spec.len and spec[j].kind == vkBlock: discard
            elif s.kind == vkBlock:
              discard  # type annotation
            j += 1
          e.bindings[name] = BindingInfo(arity: paramCount, isFunction: true, isUnknown: false,
                                          refinements: refInfos)
          # Recurse into function body
          if i + 3 < vals.len and vals[i + 3].kind == vkBlock:
            e.prescanBlock(vals[i + 3].blockVals)
          i += 4
          continue
      # name: require %path — prescan the dependency's exports
      elif i + 1 < vals.len and vals[i + 1].kind == vkWord and
           vals[i + 1].wordKind == wkWord and vals[i + 1].wordName == "import":
        if i + 2 < vals.len and vals[i + 2].kind in {vkFile, vkString}:
          let rawPath = if vals[i + 2].kind == vkFile: vals[i + 2].filePath
                        else: vals[i + 2].strVal
          let srcDir = if e.sourceDir.len > 0: e.sourceDir else: getCurrentDir()
          let absPath = if rawPath.isAbsolute: rawPath else: srcDir / rawPath
          if fileExists(absPath) and absPath notin e.compiling:
            let depSource = readFile(absPath)
            var depAst = parseSource(depSource)
            if depAst.len >= 2 and depAst[0].kind == vkWord and depAst[0].wordKind == wkWord and
               depAst[0].wordName.startsWith("Kintsugi") and depAst[1].kind == vkBlock:
              depAst = depAst[2..^1]
            # Prescan the dependency to get its bindings
            var childCompiling = e.compiling
            childCompiling.incl(absPath)
            var depEmitter = LuaEmitter(bindings: initNativeBindings(),
                                         sourceDir: parentDir(absPath),
                                         compiling: childCompiling)
            depEmitter.prescanBlock(depAst)
            # Find exports and register as path bindings
            let exports = findExports(depAst)
            let exportNames = if exports.len > 0: exports
                              else:
                                # No exports — use all top-level bindings
                                var names: seq[string] = @[]
                                for k, v in depEmitter.bindings:
                                  if k notin initNativeBindings(): # skip natives
                                    names.add(k)
                                names
            # Register name as a value (the module object)
            e.bindings[name] = BindingInfo(arity: -1, isFunction: false, isUnknown: false)
            # Register name/export as the correct binding type
            for exp in exportNames:
              let pathName = name & "/" & exp
              if exp in depEmitter.bindings:
                e.bindings[pathName] = depEmitter.bindings[exp]
          i += 3
          continue
      else:
        # name: <non-function> — it's a value
        if name notin e.bindings:
          e.bindings[name] = BindingInfo(arity: -1,
                                          isFunction: false, isUnknown: false)
    i += 1

proc findExports(ast: seq[KtgValue]): seq[string] =
  ## Scan for `exports [name1 name2 ...]` and return the exported names.
  var i = 0
  while i < ast.len:
    if ast[i].kind == vkWord and ast[i].wordKind == wkWord and
       ast[i].wordName == "exports":
      if i + 1 < ast.len and ast[i + 1].kind == vkBlock:
        for v in ast[i + 1].blockVals:
          if v.kind == vkWord and v.wordKind == wkWord:
            result.add(v.wordName)
        return result
    i += 1

proc emitLuaModule*(ast: seq[KtgValue], sourceDir: string = "",
                    compiling: HashSet[string] = initHashSet[string]()): string =
  ## Compile a Kintsugi module to Lua. Emits exports as return statement.
  var e = LuaEmitter(
    indent: 0,
    output: "",
    bindings: initNativeBindings(),
    nameMap: initTable[string, string](),
    bindingKinds: initTable[string, BindingKind](),
    sourceDir: sourceDir,
    compiling: compiling
  )
  e.prescanBlock(ast)
  e.emitBlock(ast)

  # Emit exports return
  let exports = findExports(ast)
  if exports.len > 0:
    var parts: seq[string] = @[]
    for name in exports:
      let lua = luaName(name)
      parts.add(lua & " = " & lua)
    e.ln("return {" & parts.join(", ") & "}")

  e.output

proc emitLua*(ast: seq[KtgValue], sourceDir: string = ""): string =
  ## Walk the AST and produce Lua source code.
  var e = LuaEmitter(
    indent: 0,
    output: "",
    bindings: initNativeBindings(),
    nameMap: initTable[string, string](),
    bindingKinds: initTable[string, BindingKind](),
    sourceDir: sourceDir
  )
  e.prescanBlock(ast)
  e.emitBlock(ast)
  e.buildPrelude() & e.output
