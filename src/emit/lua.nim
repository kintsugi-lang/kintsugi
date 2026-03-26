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
    arities: Table[string, int]
    ## Track locally declared names. Undeclared names emit as globals.
    locals: HashSet[string]

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
  # Type predicates — all arity 1
  for name in ["integer", "float", "string", "logic", "none", "money",
               "pair", "tuple", "date", "time", "file", "url", "email",
               "block", "paren", "map", "set", "context", "object",
               "function", "native", "word", "type", "number"]:
    result[name & "?"] = 1
  result["is?"] = 2
  # Series
  result["size?"] = 1
  result["length?"] = 1
  result["empty?"] = 1
  result["first"] = 1
  result["second"] = 1
  result["last"] = 1
  result["pick"] = 2
  result["append"] = 2
  result["copy"] = 1
  result["select"] = 2
  result["has?"] = 2
  result["index?"] = 2
  result["insert"] = 3
  result["remove"] = 2
  # String ops
  result["join"] = 2
  result["rejoin"] = 1
  result["trim"] = 1
  result["uppercase"] = 1
  result["lowercase"] = 1
  result["split"] = 2
  result["replace"] = 3
  result["substring"] = 3
  result["starts-with?"] = 2
  result["ends-with?"] = 2
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
  result["all"] = 1
  result["any"] = 1
  # Function creation
  result["function"] = 2
  result["does"] = 1
  # Context/Object
  result["context"] = 1
  result["freeze"] = 1
  result["frozen?"] = 1
  result["words-of"] = 1
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
  # Make
  result["make"] = 2
  # IO
  result["read-file"] = 1
  result["write-file"] = 2
  result["load"] = 1
  result["save"] = 2
  result["require"] = 1
  result["exports"] = 1
  # Set operations
  result["charset"] = 1
  result["union"] = 2
  result["intersect"] = 2
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
proc emitMatchExpr(e: var LuaEmitter, valueExpr: string, rulesBlock: seq[KtgValue]): string
proc emitEitherExpr(e: var LuaEmitter, cond: string, trueBlock, falseBlock: seq[KtgValue]): string

# ---------------------------------------------------------------------------
# Infix operators
# ---------------------------------------------------------------------------

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
# Path helper
# ---------------------------------------------------------------------------

proc emitPath(name: string): string =
  let parts = name.split('/')
  result = luaName(parts[0])
  for i in 1 ..< parts.len:
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

proc emitMatchStmt(e: var LuaEmitter, valueExpr: string, rulesBlock: seq[KtgValue]) =
  ## match value [...rules...] as a statement (no value produced)
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

proc emitTypePredicateCall(name: string, argExpr: string): string =
  ## Emit a type predicate as an efficient Lua expression.
  let baseName = name[0..^2]  # strip trailing ?
  let safeArg = if needsParens(argExpr): "(" & argExpr & ")" else: argExpr
  case baseName
  of "none":
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

      # --- Known refinement calls (before generic path handling) ---
      if name == "round/down":
        let arg = e.emitExpr(vals, pos)
        result = "math.floor(" & arg & ")"
      elif name == "round/up":
        let arg = e.emitExpr(vals, pos)
        result = "math.ceil(" & arg & ")"

      # --- Path access: obj/field/sub ---
      elif name.contains('/'):
        result = emitPath(name)
        # (fall through to infix handling below)

      # --- Interpreter-only features: compile error ---
      elif name == "do":
        compileError("do", "use #preprocess to evaluate dynamic blocks at compile time", val.line)

      elif name == "bind":
        compileError("bind", "bind is not available in compiled Lua output", val.line)

      elif name == "compose":
        compileError("compose", "use #preprocess for compile-time block composition", val.line)

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
          let saved = e.output
          e.output = ""
          e.emitLoop(blk)
          let loopCode = e.output
          e.output = saved
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

      elif name == "index?":
        let blk = e.emitExpr(vals, pos)
        let val_expr = e.emitExpr(vals, pos)
        result = "(function() for i,v in ipairs(" & blk & ") do if v == " & val_expr & " then return i end end; return nil end)()"

      # --- Type predicates (none?, integer?, etc.) ---
      elif isTypePredicate(name):
        let arg = e.emitExpr(vals, pos)
        result = emitTypePredicateCall(name, arg)

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

      # --- Generic function call or variable reference ---
      else:
        let a = e.arity(name)
        if a > 0:
          var args: seq[string] = @[]
          for i in 0 ..< a:
            args.add(e.emitExpr(vals, pos))
          result = luaName(name) & "(" & args.join(", ") & ")"
        elif a == 0:
          result = luaName(name) & "()"
        else:
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

    # --- Set-word at statement level ---
    if val.kind == vkWord and val.wordKind == wkSetWord:
      let rawName = val.wordName
      let isPath = rawName.contains('/')
      let name = if isPath:
                   emitPath(rawName)
                 else:
                   luaName(rawName)
      let prefix = if isPath: ""            # globals: no 'local'
                   elif name in e.locals: "" # already declared: no 'local'
                   else: "local "
      pos += 1

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
          e.arities[rawName] = params.len

          if isPath:
            e.ln(name & " = function(" & params.join(", ") & ")")
          else:
            e.ln(prefix & "function " & name & "(" & params.join(", ") & ")")
          let savedLocals = e.locals
          e.locals = initHashSet[string]()
          for p in params:
            e.locals.incl(p)
          e.indent += 1
          e.emitBody(bodyBlock, asReturn = not isPath)
          e.indent -= 1
          e.locals = savedLocals
          e.ln("end")
          continue

      # Check if RHS is `does` (0-arg function)
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName == "does":
        pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock:
          let bodyBlock = vals[pos].blockVals
          pos += 1
          e.arities[rawName] = 0
          if isPath:
            e.ln(name & " = function()")
          else:
            e.ln(prefix & "function " & name & "()")
          let savedLocals = e.locals
          e.locals = initHashSet[string]()
          e.indent += 1
          # Path assignments (love.draw etc) don't need implicit return
          e.emitBody(bodyBlock, asReturn = not isPath)
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

      # Regular assignment
      let expr = e.emitExpr(vals, pos)
      e.ln(prefix & name & " = " & expr)
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
        e.emitMatchStmt(valueExpr, rulesBlock)
        continue

    # --- print as statement ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "print":
      pos += 1
      let arg = e.emitExpr(vals, pos)
      e.ln("print(" & arg & ")")
      continue

    # --- Path call as statement (e.g., love/graphics/setColor 1.0 0.0 0.0) ---
    # Only treat as a function call if the path has known arity > 0 or there
    # are arguments following it. Otherwise treat as a plain expression.
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName.contains('/'):
      let path = emitPath(val.wordName)
      let pathArity = e.arity(val.wordName)
      if pathArity >= 0:
        # Known function at this path — consume args
        pos += 1
        var args: seq[string] = @[]
        for i in 0 ..< pathArity:
          args.add(e.emitExpr(vals, pos))
        e.ln(path & "(" & args.join(", ") & ")")
        continue
      else:
        # Check if followed by arguments (heuristic: next value is not a keyword/set-word/end)
        pos += 1
        var args: seq[string] = @[]
        while pos < vals.len:
          let next = vals[pos]
          if next.kind == vkWord and next.wordKind == wkSetWord: break
          if next.kind == vkWord and next.wordKind == wkMetaWord: break
          if next.kind == vkWord and next.wordKind == wkWord and
             next.wordName in ["if", "either", "unless", "loop", "match",
                                "print", "return", "break", "error", "try"]: break
          if next.kind == vkWord and next.wordKind == wkWord and next.wordName.contains('/'): break
          if next.kind == vkBlock: break  # blocks are not args to unknown path calls
          args.add(e.emitExpr(vals, pos))
        if args.len > 0:
          e.ln(path & "(" & args.join(", ") & ")")
        else:
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
      e.ln("table.insert(" & blk & ", " & val_expr & ")")
      continue

    # --- Generic expression as statement ---
    let expr = e.emitExpr(vals, pos)
    if expr.len > 0 and expr != "nil":
      # In Lua, a statement starting with ( is ambiguous (could be function call
      # on previous expression). Prefix with ; to disambiguate.
      if expr.startsWith("("):
        e.ln(";" & expr)
      else:
        e.ln(expr)

proc emitBlockReturn(e: var LuaEmitter, vals: seq[KtgValue]) =
  ## Like emitBlock but adds implicit return to the last expression.
  ## Walks the AST to find statement boundaries, emits all but the last
  ## statement normally, then handles the last statement with return.
  if vals.len == 0:
    return

  # Walk through to find each statement's starting position
  var stmtStarts: seq[int] = @[]
  var pos = 0
  while pos < vals.len:
    stmtStarts.add(pos)
    let val = vals[pos]

    # Skip Kintsugi header block (e.g., Kintsugi [...])
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "Kintsugi":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkBlock:
        pos += 1
      continue

    # Set-word: name + value (value may consume multiple tokens)
    if val.kind == vkWord and val.wordKind == wkSetWord:
      pos += 1
      # Consume the RHS expression to find where next statement starts
      let saved = e.output
      e.output = ""
      discard e.emitExpr(vals, pos)
      e.output = saved
      continue

    # Keywords with known structure
    if val.kind == vkWord and val.wordKind == wkWord:
      case val.wordName
      of "if", "unless":
        pos += 1
        let saved = e.output; e.output = ""
        discard e.emitExpr(vals, pos)  # condition
        e.output = saved
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1  # body block
        continue
      of "either":
        pos += 1
        let saved = e.output; e.output = ""
        discard e.emitExpr(vals, pos)  # condition
        e.output = saved
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1  # true block
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1  # false block
        continue
      of "loop":
        pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
        continue
      of "match":
        pos += 1
        let saved = e.output; e.output = ""
        discard e.emitExpr(vals, pos)  # value
        e.output = saved
        if pos < vals.len and vals[pos].kind == vkBlock: pos += 1  # rules
        continue
      of "return":
        pos += 1
        let saved = e.output; e.output = ""
        discard e.emitExpr(vals, pos)
        e.output = saved
        continue
      of "break":
        pos += 1
        continue
      of "print":
        pos += 1
        let saved = e.output; e.output = ""
        discard e.emitExpr(vals, pos)
        e.output = saved
        continue
      else: discard

    # Generic expression
    let saved = e.output; e.output = ""
    discard e.emitExpr(vals, pos)
    e.output = saved

  if stmtStarts.len == 0:
    return

  # Emit all statements except the last normally
  let lastStart = stmtStarts[^1]
  if lastStart > 0:
    e.emitBlock(vals[0 ..< lastStart])

  # Now handle the last statement with implicit return
  let lastVals = vals[lastStart .. ^1]
  if lastVals.len == 0:
    return

  let lastVal = lastVals[0]

  # If last statement starts with return or break, just emit normally
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName in ["return", "break"]:
    e.emitBlock(lastVals)
    return

  # If last statement is a set-word, emit the assignment then return the variable
  if lastVal.kind == vkWord and lastVal.wordKind == wkSetWord:
    e.emitBlock(lastVals)
    let name = if lastVal.wordName.contains('/'):
                 emitPath(lastVal.wordName)
               else:
                 luaName(lastVal.wordName)
    e.ln("return " & name)
    return

  # If last statement is if/unless, emit with return inside the block
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName in ["if", "unless"]:
    var lpos = 1
    let cond = e.emitExpr(lastVals, lpos)
    if lpos < lastVals.len and lastVals[lpos].kind == vkBlock:
      let body = lastVals[lpos].blockVals
      if lastVal.wordName == "unless":
        e.ln("if not (" & cond & ") then")
      else:
        e.ln("if " & cond & " then")
      e.indent += 1
      e.emitBlockReturn(body)
      e.indent -= 1
      e.ln("end")
      return

  # If last statement is either, emit with return in both branches
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName == "either":
    var lpos = 1
    let cond = e.emitExpr(lastVals, lpos)
    var trueBlock: seq[KtgValue] = @[]
    var falseBlock: seq[KtgValue] = @[]
    if lpos < lastVals.len and lastVals[lpos].kind == vkBlock:
      trueBlock = lastVals[lpos].blockVals
      lpos += 1
    if lpos < lastVals.len and lastVals[lpos].kind == vkBlock:
      falseBlock = lastVals[lpos].blockVals
    e.ln("if " & cond & " then")
    e.indent += 1
    e.emitBlockReturn(trueBlock)
    e.indent -= 1
    e.ln("else")
    e.indent += 1
    e.emitBlockReturn(falseBlock)
    e.indent -= 1
    e.ln("end")
    return

  # If last statement is match, emit with return in handlers
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName == "match":
    var lpos = 1
    let valueExpr = e.emitExpr(lastVals, lpos)
    if lpos < lastVals.len and lastVals[lpos].kind == vkBlock:
      let rulesBlock = lastVals[lpos].blockVals
      # Emit match as if-chain with returns
      e.emitMatchStmt(valueExpr, rulesBlock)
      # TODO: add return inside each handler
      return

  # If last statement is loop, emit normally (loops don't produce values)
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName == "loop":
    e.emitBlock(lastVals)
    return

  # If last statement is print, emit normally (print returns none)
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName == "print":
    e.emitBlock(lastVals)
    return

  # Generic expression: emit with return
  var lpos = 0
  let expr = e.emitExpr(lastVals, lpos)
  if expr != "nil":
    e.ln("return " & expr)

proc emitBody(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false) =
  ## Emit a function body. If asReturn is true, the last expression gets
  ## an implicit `return` prepended.
  if vals.len == 0:
    return

  if not asReturn:
    e.emitBlock(vals)
    return

  e.emitBlockReturn(vals)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

const LuaPrelude = """-- Kintsugi runtime support
local _NONE = setmetatable({}, {__tostring = function() return "none" end})
local function _is_none(v) return v == nil or v == _NONE end
"""

proc prescanArities(e: var LuaEmitter, ast: seq[KtgValue]) =
  ## Pre-scan the AST to collect user-defined function arities.
  ## This handles forward references (calling a function before it's defined).
  var i = 0
  while i < ast.len:
    if ast[i].kind == vkWord and ast[i].wordKind == wkSetWord:
      let name = ast[i].wordName
      # name: function [params...] [body]
      if i + 1 < ast.len and ast[i + 1].kind == vkWord and
         ast[i + 1].wordKind == wkWord and ast[i + 1].wordName == "function":
        if i + 2 < ast.len and ast[i + 2].kind == vkBlock:
          var paramCount = 0
          for s in ast[i + 2].blockVals:
            if s.kind == vkWord and s.wordKind == wkWord:
              paramCount += 1
          e.arities[name] = paramCount
          i += 4  # skip name, function, spec, body
          continue
      # name: does [body]
      if i + 1 < ast.len and ast[i + 1].kind == vkWord and
         ast[i + 1].wordKind == wkWord and ast[i + 1].wordName == "does":
        e.arities[name] = 0
        i += 3  # skip name, does, body
        continue
    i += 1

proc emitLua*(ast: seq[KtgValue]): string =
  ## Walk the AST and produce Lua source code.
  var e = LuaEmitter(
    indent: 0,
    output: "",
    arities: initNativeArities()
  )
  e.prescanArities(ast)
  e.emitBlock(ast)
  LuaPrelude & e.output
