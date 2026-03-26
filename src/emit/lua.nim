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

import std/[strutils, tables, sequtils, sets]
import ../core/types

type
  LuaEmitter = object
    indent: int
    output: string
    ## Track known function arities so we can consume the right number of args.
    ## Populated from: native arity table, user-defined function specs.
    arities: Table[string, int]

  EmitError* = ref object of CatchableError

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc pad(e: LuaEmitter): string =
  repeat("  ", e.indent)

proc ln(e: var LuaEmitter, s: string) =
  e.output &= e.pad & s & "\n"

proc raw(e: var LuaEmitter, s: string) =
  e.output &= s

proc arity(e: LuaEmitter, name: string): int =
  ## Return known arity, or -1 for unknown (treat as 0-arg variable reference).
  if name in e.arities: e.arities[name] else: -1

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

proc initNativeArities(): Table[string, int] =
  result = initTable[string, int]()
  # Output
  result["print"] = 1
  result["probe"] = 1
  # Control flow
  result["if"] = 2       # condition block
  result["either"] = 3   # condition true-block false-block
  result["unless"] = 2   # condition block
  result["not"] = 1
  result["return"] = 1
  result["break"] = 0
  # Type introspection (erased in compiled output, but arity needed for parsing)
  result["type"] = 1
  # Series
  result["size?"] = 1
  result["length?"] = 1
  result["empty?"] = 1
  result["first"] = 1
  result["last"] = 1
  result["pick"] = 2
  result["append"] = 2
  result["copy"] = 1
  result["select"] = 2
  result["has?"] = 2
  result["index?"] = 2
  # String ops
  result["join"] = 2
  result["rejoin"] = 1
  result["trim"] = 1
  result["uppercase"] = 1
  result["lowercase"] = 1
  result["split"] = 2
  result["replace"] = 3
  # Math
  result["abs"] = 1
  result["negate"] = 1
  result["min"] = 2
  result["max"] = 2
  result["round"] = 1
  result["odd?"] = 1
  result["even?"] = 1
  result["sqrt"] = 1
  # Homoiconic — do/compose/bind are compile errors in Lua mode
  result["do"] = 1
  result["reduce"] = 1
  # Function creation
  result["function"] = 2
  result["does"] = 1
  # Context/Object
  result["context"] = 1
  result["freeze"] = 1
  result["frozen?"] = 1
  # Type conversion
  result["to"] = 2
  # Apply
  result["apply"] = 2
  # Sort
  result["sort"] = 1
  # Set (destructuring)
  result["set"] = 2
  # Error handling
  result["error"] = 3
  result["try"] = 1
  # Match
  result["match"] = 2
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

# ---------------------------------------------------------------------------
# Forward declarations
# ---------------------------------------------------------------------------

proc emitExpr(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string
proc emitBody(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false)
proc emitBlock(e: var LuaEmitter, vals: seq[KtgValue])

# ---------------------------------------------------------------------------
# Infix operators
# ---------------------------------------------------------------------------

const InfixOps = ["+", "-", "*", "/", "%", "=", "<>", "<", ">", "<=", ">="].toHashSet

proc isInfixOp(val: KtgValue): bool =
  val.kind == vkOp or
    (val.kind == vkWord and val.wordKind == wkWord and val.wordName in ["and", "or"])

proc luaOp(op: string): string =
  case op
  of "=": "=="
  of "<>": "~="
  of "%": "%"
  of "and": "and"
  of "or": "or"
  else: op  # +, -, *, /, <, >, <=, >= are the same

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
  var parts: seq[string] = @[]
  var pos = 0
  while pos < vals.len:
    parts.add(e.emitExpr(vals, pos))
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
# Emit function definition
# ---------------------------------------------------------------------------

proc emitFuncDef(e: var LuaEmitter, specBlock, bodyBlock: seq[KtgValue]): string =
  ## Parse a function spec [a b] and body [...] into a Lua function expression.
  var params: seq[string] = @[]
  var i = 0
  while i < specBlock.len:
    let s = specBlock[i]
    if s.kind == vkWord and s.wordKind == wkWord:
      # Skip 'return:' set-word and its type block
      params.add(luaName(s.wordName))
    elif s.kind == vkWord and s.wordKind == wkSetWord:
      # return: [type!] — skip the type annotation
      i += 1
      if i < specBlock.len and specBlock[i].kind == vkBlock:
        discard  # skip type block
    elif s.kind == vkBlock:
      discard  # type annotation block — skip
    i += 1

  let paramStr = params.join(", ")
  var funcStr = "function(" & paramStr & ")\n"

  e.indent += 1
  # Emit body — last expression is implicit return
  e.emitBody(bodyBlock, asReturn = true)
  let bodyStr = e.output
  e.output = ""
  e.indent -= 1

  # Record arity for this function (caller will associate with name)
  funcStr &= bodyStr
  funcStr &= e.pad & "end"
  funcStr

# ---------------------------------------------------------------------------
# Emit loop dialect
# ---------------------------------------------------------------------------

proc emitLoop(e: var LuaEmitter, blk: seq[KtgValue]) =
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

        if pos < blk.len and blk[pos].kind == vkBlock:
          let varStr = if vars.len > 0: "_, " & vars[0] else: "_"
          e.ln("for " & varStr & " in ipairs(" & series & ") do")
          e.indent += 1
          if guard.len > 0:
            e.ln("if " & guard & " then")
            e.indent += 1
            e.emitBlock(blk[pos].blockVals)
            e.indent -= 1
            e.ln("end")
          else:
            e.emitBlock(blk[pos].blockVals)
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
            e.emitBlock(blk[pos].blockVals)
            e.indent -= 1
            e.ln("end")
          else:
            e.emitBlock(blk[pos].blockVals)
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
    if pos < blk.len and blk[pos].kind == vkBlock:
      var forHeader = "for it = " & fromExpr & ", " & toExpr
      if stepExpr.len > 0:
        forHeader &= ", " & stepExpr
      e.ln(forHeader & " do")
      e.indent += 1
      e.emitBlock(blk[pos].blockVals)
      e.indent -= 1
      e.ln("end")

  else:
    # Infinite loop: while true do ... end
    if blk.len > 0:
      e.ln("while true do")
      e.indent += 1
      e.emitBlock(blk)
      e.indent -= 1
      e.ln("end")

# ---------------------------------------------------------------------------
# Emit match as if-chain
# ---------------------------------------------------------------------------

proc emitMatch(e: var LuaEmitter, valueExpr: string, rulesBlock: seq[KtgValue]) =
  ## match value [...rules...]
  ## Each rule is: [pattern] [handler] or [pattern] when [guard] [handler]
  ## default: [handler]
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
        e.emitBlock(rulesBlock[pos].blockVals)
        e.indent -= 1
        pos += 1
      if not first:
        e.ln("end")
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

    e.emitBlock(handler)
    e.indent -= 1
    first = false

  if not first:
    e.ln("end")

# ---------------------------------------------------------------------------
# Compile-error guards for interpreter-only features
# ---------------------------------------------------------------------------

proc compileError(feature, hint: string, line: int) =
  raise EmitError(
    msg: "======== COMPILE ERROR ========\n" &
         "Interpreter-Only Feature\n" &
         "'" & feature & "' cannot be used in Kintsugi/Lua -- it requires runtime evaluation" &
         (if line > 0: " @ line " & $line else: "") & "\n" &
         "  hint: " & hint
  )

# ---------------------------------------------------------------------------
# Core expression emitter — returns a Lua expression string
# ---------------------------------------------------------------------------

proc emitExpr(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  ## Emit the next expression from vals starting at pos. Returns a Lua
  ## expression string and advances pos past the consumed values.
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

      # --- Path access: obj/field/sub ---
      if name.contains('/'):
        let parts = name.split('/')
        var path = luaName(parts[0])
        for i in 1 ..< parts.len:
          path &= "." & luaName(parts[i])
        result = path

        # Check if next is infix
        # (fall through to infix handling below)

      # --- Interpreter-only features: compile error ---
      elif name == "do":
        compileError("do", "use #preprocess to evaluate dynamic blocks at compile time", val.line)

      elif name == "bind":
        compileError("bind", "bind is not available in compiled Lua output", val.line)

      elif name == "compose":
        # compose on literal blocks could be resolved, but for now reject all
        compileError("compose", "use #preprocess for compile-time block composition", val.line)

      # --- No-ops: freeze/frozen? ---
      elif name == "freeze":
        # consume the arg, emit it directly (no-op)
        result = e.emitExpr(vals, pos)

      elif name == "frozen?":
        # Always false in compiled output
        discard e.emitExpr(vals, pos)  # consume arg
        result = "false"

      # --- print ---
      elif name == "print":
        let arg = e.emitExpr(vals, pos)
        result = "print(" & arg & ")"

      # --- probe (returns value) ---
      elif name == "probe":
        let arg = e.emitExpr(vals, pos)
        # probe prints and returns — wrap in a helper or just print
        result = "(function() local _v = " & arg & "; print(_v); return _v end)()"

      # --- not ---
      elif name == "not":
        let arg = e.emitExpr(vals, pos)
        result = "not " & arg

      # --- return ---
      elif name == "return":
        let arg = e.emitExpr(vals, pos)
        result = "return " & arg  # Note: used at statement level typically

      # --- if: condition block ---
      elif name == "if":
        let cond = e.emitExpr(vals, pos)
        # Next should be a block for the true branch
        if pos < vals.len and vals[pos].kind == vkBlock:
          let bodyBlock = vals[pos].blockVals
          pos += 1
          # For expression context, use Lua's `(function() if ... end)()`
          # This is the expression form; statement form is handled in emitBlock
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
        var trueExpr = "nil"
        var falseExpr = "nil"
        if pos < vals.len and vals[pos].kind == vkBlock:
          let tb = vals[pos].blockVals
          pos += 1
          if tb.len == 1:
            var tpos = 0
            trueExpr = e.emitExpr(tb, tpos)
          else:
            var tpos = 0
            # Multi-expression block — last value is the result
            while tpos < tb.len:
              trueExpr = e.emitExpr(tb, tpos)
        if pos < vals.len and vals[pos].kind == vkBlock:
          let fb = vals[pos].blockVals
          pos += 1
          if fb.len == 1:
            var fpos = 0
            falseExpr = e.emitExpr(fb, fpos)
          else:
            var fpos = 0
            while fpos < fb.len:
              falseExpr = e.emitExpr(fb, fpos)
        # Lua ternary idiom
        result = "(" & cond & " and " & trueExpr & " or " & falseExpr & ")"

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

      # --- does (0-arg function) ---
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

      # --- loop dialect ---
      elif name == "loop":
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          # Loop is a statement — emit directly. In expression context this
          # is unusual but handle it by emitting nil.
          let saved = e.output
          e.output = ""
          e.emitLoop(blk)
          let loopCode = e.output
          e.output = saved
          # Can't easily be an expression; emit inline
          e.raw(loopCode)
          result = "nil"
        else:
          result = "nil"

      # --- match dialect ---
      elif name == "match":
        let valueExpr = e.emitExpr(vals, pos)
        if pos < vals.len and vals[pos].kind == vkBlock:
          let rulesBlock = vals[pos].blockVals
          pos += 1
          let saved = e.output
          e.output = ""
          e.emitMatch(valueExpr, rulesBlock)
          let matchCode = e.output
          e.output = saved
          e.raw(matchCode)
          result = "nil"
        else:
          result = "nil"

      # --- String operations ---
      elif name == "join":
        let a = e.emitExpr(vals, pos)
        let b = e.emitExpr(vals, pos)
        result = "tostring(" & a & ") .. tostring(" & b & ")"

      elif name == "rejoin":
        let arg = e.emitExpr(vals, pos)
        # rejoin on a table — concatenate all elements
        result = "table.concat(" & arg & ")"

      elif name == "trim":
        let arg = e.emitExpr(vals, pos)
        # Lua string trim idiom
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
        # Emit a self-contained split. We use a local closure to avoid
        # polluting scope.
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
        result = "(function() table.insert(" & blk & ", " & val_expr & "); return " & blk & " end)()"

      elif name == "copy":
        let arg = e.emitExpr(vals, pos)
        result = "(function() local r={}; for i,v in ipairs(" & arg & ") do r[i]=v end; return r end)()"

      elif name == "select":
        let blk = e.emitExpr(vals, pos)
        let key = e.emitExpr(vals, pos)
        result = blk & "[" & key & "]"

      elif name == "has?":
        let blk = e.emitExpr(vals, pos)
        let val_expr = e.emitExpr(vals, pos)
        # Generic — works for table key check
        result = "(" & blk & "[" & val_expr & "] ~= nil)"

      elif name == "index?":
        let blk = e.emitExpr(vals, pos)
        let val_expr = e.emitExpr(vals, pos)
        result = "(function() for i,v in ipairs(" & blk & ") do if v == " & val_expr & " then return i end end; return nil end)()"

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

      # --- Type conversion ---
      elif name == "to":
        let targetType = e.emitExpr(vals, pos)
        let val_expr = e.emitExpr(vals, pos)
        # Best-effort type conversion
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
        let args = e.emitExpr(vals, pos)
        result = fn & "(unpack(" & args & "))"

      # --- reduce ---
      elif name == "reduce":
        let arg = e.emitExpr(vals, pos)
        # In compiled context, reduce on a literal block means evaluate each
        # element. Best we can do: return the block as-is since elements are
        # already expressions.
        result = arg

      # --- Generic function call or variable reference ---
      else:
        let a = e.arity(name)
        if a > 0:
          # Known function — consume args
          var args: seq[string] = @[]
          for i in 0 ..< a:
            args.add(e.emitExpr(vals, pos))
          result = luaName(name) & "(" & args.join(", ") & ")"
        elif a == 0:
          result = luaName(name) & "()"
        else:
          # Unknown — could be a variable or a user-defined function.
          # Peek ahead: if there are remaining values and next is NOT
          # an infix operator and NOT a set-word (i.e., looks like an arg),
          # heuristically assume it's a function call. But this is fragile.
          # For now: just emit as a variable reference. User-defined function
          # arities are tracked when we see the definition.
          result = luaName(name)

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
      var dummyPos = 0
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
    result = result & " " & opStr & " " & right

# ---------------------------------------------------------------------------
# Emit a sequence of values as Lua statements
# ---------------------------------------------------------------------------

proc emitBlock(e: var LuaEmitter, vals: seq[KtgValue]) =
  ## Emit a block of values as statements. Does not add implicit return.
  var pos = 0
  while pos < vals.len:
    let val = vals[pos]

    # --- Set-word at statement level: local name = expr ---
    if val.kind == vkWord and val.wordKind == wkSetWord:
      let name = luaName(val.wordName)
      pos += 1

      # Check if RHS is a function definition
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName == "function":
        pos += 1
        if pos + 1 < vals.len and vals[pos].kind == vkBlock and vals[pos + 1].kind == vkBlock:
          let specBlock = vals[pos].blockVals
          let bodyBlock = vals[pos + 1].blockVals
          pos += 2

          # Extract param names for the function header
          var params: seq[string] = @[]
          var i = 0
          while i < specBlock.len:
            let s = specBlock[i]
            if s.kind == vkWord and s.wordKind == wkWord:
              params.add(luaName(s.wordName))
            elif s.kind == vkBlock:
              discard  # type annotation — skip
            elif s.kind == vkWord and s.wordKind == wkSetWord:
              i += 1  # skip return type block
              if i < specBlock.len and specBlock[i].kind == vkBlock: discard
            i += 1

          # Track arity for this function
          e.arities[val.wordName] = params.len

          e.ln("local function " & name & "(" & params.join(", ") & ")")
          e.indent += 1
          e.emitBody(bodyBlock, asReturn = true)
          e.indent -= 1
          e.ln("end")
          continue

      # Check if RHS is `does` (0-arg function)
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName == "does":
        pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock:
          let bodyBlock = vals[pos].blockVals
          pos += 1
          e.arities[val.wordName] = 0
          e.ln("local function " & name & "()")
          e.indent += 1
          e.emitBody(bodyBlock, asReturn = true)
          e.indent -= 1
          e.ln("end")
          continue

      # Regular assignment
      let expr = e.emitExpr(vals, pos)
      e.ln("local " & name & " = " & expr)
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

    # --- loop as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "loop":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock:
        let blk = vals[pos].blockVals
        pos += 1
        e.emitLoop(blk)
        continue

    # --- match as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "match":
      pos += 1
      let valueExpr = e.emitExpr(vals, pos)
      if pos < vals.len and vals[pos].kind == vkBlock:
        let rulesBlock = vals[pos].blockVals
        pos += 1
        e.emitMatch(valueExpr, rulesBlock)
        continue

    # --- print as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "print":
      pos += 1
      let arg = e.emitExpr(vals, pos)
      e.ln("print(" & arg & ")")
      continue

    # --- Generic expression as statement ---
    let expr = e.emitExpr(vals, pos)
    if expr.len > 0 and expr != "nil":
      e.ln(expr)

proc emitBody(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false) =
  ## Emit a function body. If asReturn is true, the last expression gets
  ## an implicit `return` prepended.
  if vals.len == 0:
    return

  if not asReturn:
    e.emitBlock(vals)
    return

  # Find the last "statement" boundary: we need to emit all but the last
  # statement normally, then emit the last one with a return.
  # Simple heuristic: walk through and track statement boundaries.
  # For now, we emit all statements, then patch the last line.

  # Strategy: emit everything, capture the output, and prepend "return" to
  # the last non-empty line if it doesn't already have return/break/if/for/end.
  let saved = e.output
  e.output = ""
  e.emitBlock(vals)
  var lines = e.output.splitLines()
  e.output = saved

  # Find last non-empty, non-end line
  var lastIdx = -1
  for i in countdown(lines.len - 1, 0):
    let stripped = lines[i].strip()
    if stripped.len > 0 and stripped != "end" and
       not stripped.startsWith("if ") and
       not stripped.startsWith("elseif ") and
       not stripped.startsWith("else") and
       not stripped.startsWith("for ") and
       not stripped.startsWith("while ") and
       not stripped.startsWith("local function ") and
       not stripped.startsWith("return ") and
       not stripped.startsWith("break"):
      lastIdx = i
      break

  if lastIdx >= 0:
    let stripped = lines[lastIdx].strip()
    # Don't add return to lines that are already control structures
    if not stripped.startsWith("local "):
      let indent_str = lines[lastIdx][0 ..< lines[lastIdx].len - stripped.len]
      lines[lastIdx] = indent_str & "return " & stripped
    else:
      # For `local x = expr`, add return x after
      let parts = stripped.split(" = ", maxsplit = 1)
      if parts.len >= 1:
        let varDecl = parts[0]  # "local x"
        let varName = varDecl.replace("local ", "").strip()
        lines.insert(lines[lastIdx][0 ..< lines[lastIdx].len - stripped.len] & "return " & varName, lastIdx + 1)

  for line in lines:
    if line.len > 0:
      e.raw(line & "\n")

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc emitLua*(ast: seq[KtgValue]): string =
  ## Walk the AST and produce Lua source code.
  var e = LuaEmitter(
    indent: 0,
    output: "",
    arities: initNativeArities()
  )
  e.emitBlock(ast)
  e.output


# ---------------------------------------------------------------------------
# Test cases (as comments)
# ---------------------------------------------------------------------------

# Input Kintsugi:
#   x: 42
# Expected Lua:
#   local x = 42
#
# Input Kintsugi:
#   x: 1 + 2
# Expected Lua:
#   local x = 1 + 2
#
# Input Kintsugi:
#   add: function [a b] [a + b]
# Expected Lua:
#   local function add(a, b)
#     return a + b
#   end
#
# Input Kintsugi:
#   print "hello"
# Expected Lua:
#   print("hello")
#
# Input Kintsugi:
#   if x > 10 [print "big"]
# Expected Lua:
#   if x > 10 then
#     print("big")
#   end
#
# Input Kintsugi:
#   either x > 0 [print "pos"] [print "neg"]
# Expected Lua:
#   if x > 0 then
#     print("pos")
#   else
#     print("neg")
#   end
#
# Input Kintsugi:
#   loop [for [i] from 1 to 10 [print i]]
# Expected Lua:
#   for i = 1, 10 do
#     print(i)
#   end
#
# Input Kintsugi:
#   loop [for [item] in items [print item]]
# Expected Lua:
#   for _, item in ipairs(items) do
#     print(item)
#   end
#
# Input Kintsugi:
#   match x [
#     [1] [print "one"]
#     [2] [print "two"]
#     default: [print "other"]
#   ]
# Expected Lua:
#   if x == 1 then
#     print("one")
#   elseif x == 2 then
#     print("two")
#   else
#     print("other")
#   end
#
# Input Kintsugi:
#   player: context [
#     name: "Ray"
#     score: 0
#   ]
# Expected Lua:
#   local player = {
#     name = "Ray",
#     score = 0
#   }
#
# Input Kintsugi:
#   pos: 100x200
# Expected Lua:
#   local pos = {x=100, y=200}
#
# Input Kintsugi:
#   price: $12.50
# Expected Lua:
#   local price = 1250
#
# Input Kintsugi:
#   greet: does [print "hello"]
# Expected Lua:
#   local function greet()
#     return print("hello")
#   end
#
# Input Kintsugi:
#   player/name
# Expected Lua:
#   player.name
#
# Input Kintsugi:
#   items: [1 2 3]
# Expected Lua:
#   local items = {1, 2, 3}
#
# Input Kintsugi:
#   n: size? items
# Expected Lua:
#   local n = #items
#
# Input Kintsugi:
#   freeze obj
# Expected Lua:
#   obj
#
# Input Kintsugi:
#   frozen? obj
# Expected Lua:
#   false
