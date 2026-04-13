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
when not defined(js):
  import std/os
import ../core/[types, natives_shared]
import ../parse/parser

type
  BindingKind* = enum
    bkCall    ## function call with N args
    bkConst   ## bare reference, no parens
    bkAlias   ## name mapping, emits as-is
    bkAssign  ## callback assignment target
    bkOverride ## function definition: emits `function lua.path(...)` form
    bkMethod  ## method call: emits obj:method(args) with : syntax

  RefinementInfo* = object
    name*: string
    paramCount*: int

  BindingInfo* = object
    arity*: int          ## -1 = value (not callable), 0+ = function with N params
    isFunction*: bool    ## true = definitely a function, false = definitely a value
    isUnknown*: bool     ## true = couldn't determine (use heuristic)
    isParam*: bool       ## true = function parameter, try calling with 1 arg in head position
    refinements*: seq[RefinementInfo]
    returnArity*: int    ## -1 = unknown return, 0+ = returns a function with N params

  LuaEmitter = object
    indent: int
    output: string
    bindings: Table[string, BindingInfo]
    ## Track locally declared names. Undeclared names emit as globals.
    locals: HashSet[string]
    ## All set-word names at module scope, collected in a pre-pass
    ## before emission. Used at function-entry to make write-through
    ## work for names declared later in source order than the function.
    moduleNames: HashSet[string]
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
    ## Track custom type names (from object definitions) for type tag emission.
    customTypes: HashSet[string]
    ## Object field specs: typeName -> seq[(fieldName, defaultExpr, fieldType)].
    ## Populated during prescan so make can inline fields and rejoin can check types.
    objectFields: Table[string, seq[tuple[name: string, default: string, fieldType: string]]]
    ## Custom types that have is? checks — only these need _type tags.
    usedTypeChecks: HashSet[string]
    ## Track variable -> object type (kebab-case). Populated when we see name: make Type [...].
    varTypes: Table[string, string]
    ## Variables known to be safe for Lua's .. operator (strings, numbers).
    concatSafeVars: HashSet[string]
    ## Function return types: funcName -> type string ("integer!", "string!", etc.)
    funcReturnTypes: Table[string, string]
    ## Sequence type tracking: variable name -> stString/stBlock.
    ## Used to emit correct Lua for operations that differ between strings and blocks.
    varSeqTypes: Table[string, SeqType]

  SeqType* = enum
    stUnknown
    stString
    stBlock

  EmitError* = ref object of CatchableError

  ## An expression emitter: given vals and pos, consume arguments and return a Lua expression string.
  ExprHandler = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string

  ## A statement emitter: given vals and pos, consume arguments and emit Lua statements via e.ln().
  StmtHandler = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int)

var exprHandlers = initTable[string, ExprHandler]()
var stmtHandlers = initTable[string, StmtHandler]()

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

const SafeConcatTypes = ["integer!", "float!", "string!", "money!"]

proc isFieldSafeForConcat(e: LuaEmitter, varName, fieldName: string): bool =
  ## Check if varName.fieldName is a type safe for Lua's .. operator.
  ## Safe types: integer!, float!, string!, money! (all auto-coerce or are strings).
  let kebabVar = varName.replace("_", "-")
  if kebabVar in e.varTypes:
    let typeName = e.varTypes[kebabVar]
    if typeName in e.objectFields:
      for field in e.objectFields[typeName]:
        if field.name == fieldName:
          return field.fieldType in SafeConcatTypes
  false

proc ln(e: var LuaEmitter, s: string) =
  e.output &= e.pad & s & "\n"

proc raw(e: var LuaEmitter, s: string) =
  e.output &= s

template withCapture(e: var LuaEmitter, body: untyped): string =
  ## Capture emitter output in a temporary buffer.
  ## Returns the captured output string; restores e.output after.
  let wcSaved = e.output
  e.output = ""
  body
  let wcResult = e.output
  e.output = wcSaved
  wcResult

proc getBinding(e: LuaEmitter, name: string): BindingInfo =
  if name in e.bindings: e.bindings[name]
  else: BindingInfo(arity: -1, isFunction: false, isUnknown: true, returnArity: -1)

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

proc bindingFunc(arity: int, refInfos: seq[RefinementInfo] = @[], retArity: int = -1): BindingInfo =
  BindingInfo(arity: arity, isFunction: true, isUnknown: false, refinements: refInfos, returnArity: retArity)

proc bindingVal(): BindingInfo =
  BindingInfo(arity: -1, isFunction: false, isUnknown: false, returnArity: -1)

proc initNativeBindings(): Table[string, BindingInfo] =
  result = initTable[string, BindingInfo]()
  for (name, arity) in nativeArities:
    result[name] = bindingFunc(arity)
  for name in typePredNames:
    result[name & "?"] = bindingFunc(1)

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

proc emitExpr(e: var LuaEmitter, vals: seq[KtgValue], pos: var int,
              primary: bool = false): string
proc emitBody(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false)
proc emitBlock(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false)
proc emitMatchExpr(e: var LuaEmitter, valueExpr: string, rulesBlock: seq[KtgValue]): string
proc emitMatchHoisted(e: var LuaEmitter, varName: string, valueExpr: string,
                      rulesBlock: seq[KtgValue])
proc emitAttemptExpr(e: var LuaEmitter, blk: seq[KtgValue]): string
proc emitEitherExpr(e: var LuaEmitter, cond: string, trueBlock, falseBlock: seq[KtgValue]): string
proc emitLuaModule*(ast: seq[KtgValue], sourceDir: string = "",
                    compiling: HashSet[string] = initHashSet[string]()): string
proc findExports(ast: seq[KtgValue]): seq[string]
proc emitContextBlock(e: var LuaEmitter, vals: seq[KtgValue]): string
proc inferSeqType(e: LuaEmitter, vals: seq[KtgValue], pos: int): SeqType

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
# Handler factories
# ---------------------------------------------------------------------------

## Factory for math.X(arg) patterns — single-argument Lua math functions.
proc mathUnary(luaFn: string): ExprHandler =
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
    luaFn & "(" & e.emitExpr(vals, pos) & ")"

## Factory for string.X(arg) patterns — single-argument Lua string functions.
proc stringUnary(luaFn: string): ExprHandler =
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
    luaFn & "(" & e.emitExpr(vals, pos) & ")"

## Factory for math.X(a, b) patterns — two-argument Lua math functions.
proc mathBinary(luaFn: string): ExprHandler =
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
    let a = e.emitExpr(vals, pos)
    let b = e.emitExpr(vals, pos)
    luaFn & "(" & a & ", " & b & ")"

# ---------------------------------------------------------------------------
# Math expression handlers
# ---------------------------------------------------------------------------

# Unary math.X(arg) natives
exprHandlers["abs"] = mathUnary("math.abs")
exprHandlers["sqrt"] = mathUnary("math.sqrt")
exprHandlers["sin"] = mathUnary("math.sin")
exprHandlers["cos"] = mathUnary("math.cos")
exprHandlers["tan"] = mathUnary("math.tan")
exprHandlers["asin"] = mathUnary("math.asin")
exprHandlers["acos"] = mathUnary("math.acos")
exprHandlers["exp"] = mathUnary("math.exp")
exprHandlers["log"] = mathUnary("math.log")
exprHandlers["log10"] = mathUnary("math.log10")
exprHandlers["to-degrees"] = mathUnary("math.deg")
exprHandlers["to-radians"] = mathUnary("math.rad")
exprHandlers["floor"] = mathUnary("math.floor")
exprHandlers["ceil"] = mathUnary("math.ceil")

# Binary math.X(a, b) natives
exprHandlers["min"] = mathBinary("math.min")
exprHandlers["max"] = mathBinary("math.max")
exprHandlers["atan2"] = mathBinary("math.atan2")
exprHandlers["pow"] = mathBinary("math.pow")

# Custom math handlers
exprHandlers["negate"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  "-(" & arg & ")"

exprHandlers["odd?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  "(" & arg & " % 2 ~= 0)"

exprHandlers["even?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  "(" & arg & " % 2 == 0)"

exprHandlers["round"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  "math.floor(" & arg & " + 0.5)"

exprHandlers["pi"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "math.pi"

# ---------------------------------------------------------------------------
# String expression handlers
# ---------------------------------------------------------------------------

exprHandlers["uppercase"] = stringUnary("string.upper")
exprHandlers["lowercase"] = stringUnary("string.lower")

exprHandlers["trim"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  "(" & arg & "):match(\"^%s*(.-)%s*$\")"

exprHandlers["length"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "#" & e.emitExpr(vals, pos)

exprHandlers["empty?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  "(#" & arg & " == 0)"

# ---------------------------------------------------------------------------
# Type predicate expression handlers
# ---------------------------------------------------------------------------

proc needsParens(expr: string): bool =
  ## Check if an expression needs wrapping in parens for use as an operand.
  ## Needed when the expression contains and/or which have lower precedence than ==.
  " and " in expr or " or " in expr

## Factory for simple (type(arg) == "X") type predicates.
proc typePred(luaType: string): ExprHandler =
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
    "(type(" & e.emitExpr(vals, pos) & ") == \"" & luaType & "\")"

## Factory for generic fallback type predicates (type(arg) == "baseName").
proc typePredGeneric(baseName: string): ExprHandler =
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
    "(type(" & e.emitExpr(vals, pos) & ") == \"" & baseName & "\")"

# Simple type(arg) == "X" predicates
exprHandlers["string?"] = typePred("string")
exprHandlers["logic?"] = typePred("boolean")
exprHandlers["number?"] = typePred("number")

# Table-backed types
exprHandlers["block?"] = typePred("table")
exprHandlers["context?"] = typePred("table")
exprHandlers["object?"] = typePred("table")
exprHandlers["map?"] = typePred("table")

# Freeze - no-op in compiled output
exprHandlers["freeze"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  e.emitExpr(vals, pos, primary = true)
exprHandlers["frozen?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  discard e.emitExpr(vals, pos, primary = true)
  "false"

# Function types
exprHandlers["function?"] = typePred("function")
exprHandlers["native?"] = typePred("function")

# none? — uses _is_none helper
exprHandlers["none?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  "(" & arg & " == nil)"

# integer? — number + floor check (references arg multiple times, needs safeArg)
exprHandlers["integer?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  let safeArg = if needsParens(arg): "(" & arg & ")" else: arg
  "(type(" & safeArg & ") == \"number\" and math.floor(" & safeArg & ") == " & safeArg & ")"

# float? — number + not-integer check (references arg multiple times, needs safeArg)
exprHandlers["float?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  let safeArg = if needsParens(arg): "(" & arg & ")" else: arg
  "(type(" & safeArg & ") == \"number\" and math.floor(" & safeArg & ") ~= " & safeArg & ")"

# Generic fallback predicates — types that emit type(arg) == "baseName"
for baseName in ["money", "pair", "tuple", "date", "time", "file", "url",
                 "email", "set", "paren", "word", "type"]:
  exprHandlers[baseName & "?"] = typePredGeneric(baseName)

# ---------------------------------------------------------------------------
# Infix operators
# ---------------------------------------------------------------------------

proc wrapIfTableCtor(expr: string): string =
  ## Wrap table constructors in parens so they can be indexed: ({...})[n]
  if expr.len > 0 and expr[0] == '{': "(" & expr & ")"
  else: expr

# ---------------------------------------------------------------------------
# Simple native expression handlers
# ---------------------------------------------------------------------------

# --- raw: write string verbatim to Lua output ---
exprHandlers["raw"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  if arg.startsWith("\"") and arg.endsWith("\""): arg[1..^2]
  else: arg

# --- Refinement natives ---
exprHandlers["round/down"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "math.floor(" & e.emitExpr(vals, pos) & ")"

exprHandlers["round/up"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "math.ceil(" & e.emitExpr(vals, pos) & ")"

exprHandlers["copy/deep"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  e.useHelper("_deep_copy")
  "_deep_copy(" & arg & ")"

exprHandlers["sort/by"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arr = e.emitExpr(vals, pos)
  let keyFn = e.emitExpr(vals, pos)
  "(function() local _key = " & keyFn & "; table.sort(" & arr & ", function(a, b) return _key(a) < _key(b) end); return " & arr & " end)()"

exprHandlers["sort/with"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arr = e.emitExpr(vals, pos)
  let cmpFn = e.emitExpr(vals, pos)
  "(function() table.sort(" & arr & ", " & cmpFn & "); return " & arr & " end)()"

# --- system/platform → compile-time constant ---
exprHandlers["system/platform"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "\"lua\""

# --- now → os.time() (epoch timestamp) ---
exprHandlers["now"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "os.time()"

# --- is? — unified type checking ---
exprHandlers["is?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  # First arg is a type name (vkType), second is the value
  let typeExpr = e.emitExpr(vals, pos, primary = true)
  let valExpr = e.emitExpr(vals, pos, primary = true)
  # typeExpr is emitted as a string literal like "integer!"
  # Strip quotes and ! to get the base name
  var typeName = typeExpr.strip(chars = {'"'})
  if typeName.endsWith("!"):
    typeName = typeName[0..^2]
  # Built-in type checks that Lua can verify
  case typeName
  of "integer": "(type(" & valExpr & ") == \"number\" and math.floor(" & valExpr & ") == " & valExpr & ")"
  of "float": "(type(" & valExpr & ") == \"number\" and math.floor(" & valExpr & ") ~= " & valExpr & ")"
  of "number": "(type(" & valExpr & ") == \"number\")"
  of "string": "(type(" & valExpr & ") == \"string\")"
  of "logic": "(type(" & valExpr & ") == \"boolean\")"
  of "function", "native": "(type(" & valExpr & ") == \"function\")"
  of "block", "context", "map", "object": "(type(" & valExpr & ") == \"table\")"
  of "none":
    "(" & valExpr & " == nil)"
  else:
    # Custom type — check _type tag
    "(" & valExpr & " ~= nil and type(" & valExpr & ") == \"table\" and " & valExpr & "._type == \"" & typeName & "\")"

# --- print ---
exprHandlers["print"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "print(" & e.emitExpr(vals, pos) & ")"

# --- probe (returns value) ---
exprHandlers["probe"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  "(function() local _v = " & arg & "; print(_v); return _v end)()"

# --- not ---
exprHandlers["not"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  if arg.startsWith("(") or arg.startsWith("not "): "not " & arg
  else: "not (" & arg & ")"

# --- return ---
exprHandlers["return"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "return " & e.emitExpr(vals, pos)

# --- join ---
exprHandlers["join"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let a = e.emitExpr(vals, pos)
  let b = e.emitExpr(vals, pos)
  "tostring(" & a & ") .. tostring(" & b & ")"

# --- Series operations ---
exprHandlers["first"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let seqType = e.inferSeqType(vals, pos)
  let arg = wrapIfTableCtor(e.emitExpr(vals, pos))
  case seqType
  of stString: arg & ":sub(1, 1)"
  else: arg & "[1]"

exprHandlers["second"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let seqType = e.inferSeqType(vals, pos)
  let arg = wrapIfTableCtor(e.emitExpr(vals, pos))
  case seqType
  of stString: arg & ":sub(2, 2)"
  else: arg & "[2]"

exprHandlers["last"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let seqType = e.inferSeqType(vals, pos)
  let arg = e.emitExpr(vals, pos)
  # Simple identifier: emit arg[#arg]. Complex expression: use temp to avoid double eval.
  let isSimple = arg.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '.'})
  case seqType
  of stString:
    if isSimple: arg & ":sub(#" & arg & ", #" & arg & ")"
    else: "(function() local _t = " & arg & "; return _t:sub(#_t, #_t) end)()"
  else:
    if isSimple: arg & "[#" & arg & "]"
    else: "(function() local _t = " & arg & "; return _t[#_t] end)()"

exprHandlers["pick"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let seqType = e.inferSeqType(vals, pos)
  let blk = e.emitExpr(vals, pos)
  let idx = e.emitExpr(vals, pos)
  let wrapped = wrapIfTableCtor(blk)
  case seqType
  of stString: wrapped & ":sub(" & idx & ", " & idx & ")"
  else: wrapped & "[" & idx & "]"

exprHandlers["append"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let blk = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  e.useHelper("_append")
  "_append(" & blk & ", " & val_expr & ")"

exprHandlers["append/only"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let blk = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  "(function() table.insert(" & blk & ", " & val_expr & "); return " & blk & " end)()"

exprHandlers["copy"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let arg = e.emitExpr(vals, pos)
  e.useHelper("_copy")
  "_copy(" & arg & ")"

exprHandlers["insert"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let seqType = e.inferSeqType(vals, pos)
  let blk = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  let idx_expr = e.emitExpr(vals, pos)
  case seqType
  of stString:
    blk & ":sub(1, " & idx_expr & " - 1) .. " & val_expr & " .. " & blk & ":sub(" & idx_expr & ")"
  of stBlock:
    "(function() table.insert(" & blk & ", " & idx_expr & ", " & val_expr & "); return " & blk & " end)()"
  of stUnknown:
    e.useHelper("_insert")
    "_insert(" & blk & ", " & val_expr & ", " & idx_expr & ")"

exprHandlers["remove"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let seqType = e.inferSeqType(vals, pos)
  let blk = e.emitExpr(vals, pos)
  let idx_expr = e.emitExpr(vals, pos)
  case seqType
  of stString:
    blk & ":sub(1, " & idx_expr & " - 1) .. " & blk & ":sub(" & idx_expr & " + 1)"
  of stBlock:
    "(function() table.remove(" & blk & ", " & idx_expr & "); return " & blk & " end)()"
  of stUnknown:
    e.useHelper("_remove")
    "_remove(" & blk & ", " & idx_expr & ")"

exprHandlers["select"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let blk = e.emitExpr(vals, pos)
  let key = e.emitExpr(vals, pos)
  e.useHelper("_select")
  e.useHelper("_equals")
  "_select(" & blk & ", " & key & ")"

exprHandlers["has?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  # Peek at needle AST to detect scalar literals
  let isScalar = pos + 1 < vals.len and
    (vals[pos + 1].kind in {vkString, vkInteger, vkFloat} or
     (vals[pos + 1].kind == vkWord and vals[pos + 1].wordKind == wkWord and
      vals[pos + 1].wordName in ["true", "false"]))
  let seqType = e.inferSeqType(vals, pos)
  let blk = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  # String: substring search
  if seqType == stString:
    return "(string.find(" & blk & ", " & val_expr & ", 1, true) ~= nil)"
  if isScalar:
    # Inline loop with == for scalars — no need for _equals
    "(function() for _, x in ipairs(" & blk & ") do if x == " & val_expr &
      " then return true end end return false end)()"
  else:
    e.useHelper("_has")
    e.useHelper("_equals")
    "_has(" & blk & ", " & val_expr & ")"

# --- String operations ---
exprHandlers["split"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let str = e.emitExpr(vals, pos)
  let delim = e.emitExpr(vals, pos)
  e.useHelper("_split")
  "_split(" & str & ", " & delim & ")"

exprHandlers["replace"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let str = e.emitExpr(vals, pos)
  let old = e.emitExpr(vals, pos)
  let new_str = e.emitExpr(vals, pos)
  e.useHelper("_replace")
  "_replace(" & str & ", " & old & ", " & new_str & ")"

exprHandlers["byte"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "string.byte(" & e.emitExpr(vals, pos) & ", 1)"

exprHandlers["char"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "string.char(" & e.emitExpr(vals, pos) & ")"

exprHandlers["starts-with?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let str = e.emitExpr(vals, pos)
  let prefix = e.emitExpr(vals, pos)
  "(string.sub(" & str & ", 1, #" & prefix & ") == " & prefix & ")"

exprHandlers["ends-with?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let str = e.emitExpr(vals, pos)
  let suffix = e.emitExpr(vals, pos)
  "(string.sub(" & str & ", -#" & suffix & ") == " & suffix & ")"

exprHandlers["subset"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let seqType = e.inferSeqType(vals, pos)
  let str = e.emitExpr(vals, pos)
  let start = e.emitExpr(vals, pos)
  let length = e.emitExpr(vals, pos)
  case seqType
  of stString:
    "string.sub(" & str & ", " & start & ", " & start & " + " & length & " - 1)"
  of stBlock:
    # Inline block slice — no helper
    "(function() local r={} local _t=" & str & " local _s=" & start & " local _n=math.min(_s+" & length & "-1, #_t) for _i=_s,_n do r[#r+1]=_t[_i] end return r end)()"
  of stUnknown:
    e.useHelper("_subset")
    "_subset(" & str & ", " & start & ", " & length & ")"

# --- random ---
exprHandlers["random"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "math.random() * " & e.emitExpr(vals, pos)

exprHandlers["random/int"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let n = e.emitExpr(vals, pos)
  "math.random(" & n & ")"

exprHandlers["random/int/range"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let lo = e.emitExpr(vals, pos)
  let hi = e.emitExpr(vals, pos)
  "math.random(" & lo & ", " & hi & ")"

exprHandlers["random/choice"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let blk = e.emitExpr(vals, pos)
  "(function() local _t = " & blk & "; return _t[math.random(#_t)] end)()"

exprHandlers["random/seed"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "math.randomseed(" & e.emitExpr(vals, pos) & ")"

# --- Type conversion ---
exprHandlers["to"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let typeExpr = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  if typeExpr == "\"string!\"": "tostring(" & val_expr & ")"
  elif typeExpr == "\"integer!\"": "math.floor(tonumber(" & val_expr & "))"
  elif typeExpr == "\"float!\"": "tonumber(" & val_expr & ")"
  else: "tonumber(" & val_expr & ") or " & val_expr

# --- Type introspection ---
exprHandlers["type"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  "type(" & e.emitExpr(vals, pos) & ")"

# --- error: raise a tagged error table so catch handlers can dispatch on kind ---
exprHandlers["error"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let kind = e.emitExpr(vals, pos)
  let msg = e.emitExpr(vals, pos)
  let data = e.emitExpr(vals, pos)
  "error({kind = " & kind & ", msg = " & msg & ", data = " & data & "})"

# --- sort ---
exprHandlers["sort"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let seqType = e.inferSeqType(vals, pos)
  let arg = e.emitExpr(vals, pos)
  case seqType
  of stString:
    "(function() local t = {} for i = 1, #" & arg & " do t[i] = " & arg & ":sub(i,i) end table.sort(t) return table.concat(t) end)()"
  of stBlock:
    "(function() table.sort(" & arg & "); return " & arg & " end)()"
  of stUnknown:
    e.useHelper("_sort")
    "_sort(" & arg & ")"

# --- apply ---
exprHandlers["apply"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let fn = e.emitExpr(vals, pos)
  let args_expr = e.emitExpr(vals, pos)
  e.useHelper("_unpack")
  fn & "(unpack(" & args_expr & "))"

# --- reduce (passthrough) ---
exprHandlers["reduce"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  e.emitExpr(vals, pos)

# --- all/any: short-circuit boolean combinators ---
exprHandlers["all?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    var parts: seq[string] = @[]
    var bpos = 0
    while bpos < blk.len:
      parts.add(e.emitExpr(blk, bpos))
    "(" & parts.join(" and ") & ")"
  else:
    "true"

exprHandlers["any?"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    var parts: seq[string] = @[]
    var bpos = 0
    while bpos < blk.len:
      parts.add(e.emitExpr(blk, bpos))
    "(" & parts.join(" or ") & ")"
  else:
    "false"

# --- merge: create new table with entries from both sources ---
exprHandlers["merge"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let a = e.emitExpr(vals, pos, primary = true)
  let b = e.emitExpr(vals, pos, primary = true)
  "(function() local r = {} for k, v in pairs(" & a & ") do r[k] = v end for k, v in pairs(" & b & ") do r[k] = v end return r end)()"

# --- object: emit as table with field defaults and methods ---
exprHandlers["object"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let specBlock = vals[pos].blockVals
    pos += 1
    # Parse field declarations into {name = default, ...} table
    var parts: seq[string] = @[]
    var i = 0
    while i < specBlock.len:
      let v = specBlock[i]
      if v.kind == vkWord and v.wordKind == wkWord:
        # fields [required [...] optional [...]] — bulk declaration
        if v.wordName == "fields" and
           i + 1 < specBlock.len and specBlock[i + 1].kind == vkBlock:
          let fieldsBlock = specBlock[i + 1].blockVals
          var fi = 0
          while fi < fieldsBlock.len:
            if fieldsBlock[fi].kind == vkWord and fieldsBlock[fi].wordKind == wkWord:
              let section = fieldsBlock[fi].wordName
              fi += 1
              if fi < fieldsBlock.len and fieldsBlock[fi].kind == vkBlock:
                let sectionBlock = fieldsBlock[fi].blockVals
                fi += 1
                # Parse name [type!] default? triples
                var si = 0
                while si < sectionBlock.len:
                  if sectionBlock[si].kind == vkWord and sectionBlock[si].wordKind == wkWord:
                    let fieldName = luaName(sectionBlock[si].wordName)
                    si += 1
                    # Skip type annotation block
                    if si < sectionBlock.len and sectionBlock[si].kind == vkBlock:
                      si += 1
                    # Check for default: it's a default if the next value is NOT
                    # a new field declaration (word followed by type block)
                    let isNextField = si < sectionBlock.len and
                      sectionBlock[si].kind == vkWord and sectionBlock[si].wordKind == wkWord and
                      si + 1 < sectionBlock.len and sectionBlock[si + 1].kind == vkBlock
                    if section == "optional" and si < sectionBlock.len and not isNextField:
                      var dpos = si
                      let defaultVal = e.emitExpr(sectionBlock, dpos)
                      si = dpos
                      parts.add(fieldName & " = " & defaultVal)
                    else:
                      parts.add(fieldName & " = nil")
                  else:
                    si += 1
              else:
                fi += 1
            else:
              fi += 1
          i += 2
          continue
        # field/optional [name [type!] default] or field/required [name [type!]]
        if v.wordName in ["field/optional", "field/required"] and
           i + 1 < specBlock.len and specBlock[i + 1].kind == vkBlock:
          let fieldBlock = specBlock[i + 1].blockVals
          if fieldBlock.len >= 1 and fieldBlock[0].kind == vkWord:
            let fieldName = luaName(fieldBlock[0].wordName)
            if v.wordName == "field/optional" and fieldBlock.len >= 3:
              # field/optional [name [type!] default]
              var fpos = 2
              let defaultVal = e.emitExpr(fieldBlock, fpos)
              parts.add(fieldName & " = " & defaultVal)
            else:
              # field/required — no default, emit nil
              parts.add(fieldName & " = nil")
          i += 2
          continue
      # set-word: method or computed field
      if v.kind == vkWord and v.wordKind == wkSetWord:
        i += 1
        let fieldName = luaName(v.wordName)
        let value = e.emitExpr(specBlock, i)
        parts.add(fieldName & " = " & value)
        continue
      i += 1
    if parts.len == 0:
      result = "{}"
    else:
      result = "{\n" & parts.mapIt(repeat("  ", e.indent + 1) & it).join(",\n") & "\n" & e.pad & "}"
  else:
    result = "{}"

# --- make: emit inline table merging object defaults with overrides ---
exprHandlers["make"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  let objExpr = e.emitExpr(vals, pos, primary = true)
  let objName = objExpr.toLower.replace("_", "-")
  # Parse overrides into a name->expr table
  var overrides: seq[tuple[name: string, value: string]] = @[]
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    var bp = 0
    while bp < blk.len:
      if blk[bp].kind == vkWord and blk[bp].wordKind == wkSetWord:
        let fieldName = luaName(blk[bp].wordName)
        bp += 1
        let value = e.emitExpr(blk, bp)
        overrides.add((name: fieldName, value: value))
      else:
        bp += 1
  else:
    # Dynamic overrides expression - fall back to _make
    let overridesExpr = e.emitExpr(vals, pos, primary = true)
    e.useHelper("_make")
    discard  # prototype needed at runtime
    if objName in e.customTypes:
      return "_make(" & objExpr & ", " & overridesExpr & ", \"" & objName & "\")"
    else:
      return "_make(" & objExpr & ", " & overridesExpr & ")"
  # If we know this object's field specs, inline the merged table
  if objName in e.objectFields:
    let fields = e.objectFields[objName]
    var overrideMap = initTable[string, string]()
    for ov in overrides:
      overrideMap[ov.name] = ov.value
    var parts: seq[string] = @[]
    # Emit each field: override value if provided, else default
    for field in fields:
      if field.name in overrideMap:
        parts.add(field.name & " = " & overrideMap[field.name])
      else:
        parts.add(field.name & " = " & field.default)
    # Add any override fields not in the spec (methods, extra fields)
    for ov in overrides:
      var found = false
      for field in fields:
        if field.name == ov.name:
          found = true
          break
      if not found:
        parts.add(ov.name & " = " & ov.value)
    # Add _type tag only if is? is used for this type
    if objName in e.customTypes and objName in e.usedTypeChecks:
      parts.add("_type = \"" & objName & "\"")
    if parts.len == 0:
      "{}"
    else:
      "{\n" & parts.mapIt(repeat("  ", e.indent + 1) & it).join(",\n") & "\n" & e.pad & "}"
  else:
    # Unknown object - fall back to _make (prototype table needed at runtime)
    e.useHelper("_make")
    discard  # prototype needed at runtime
    let overridesExpr = "{" & overrides.mapIt(it.name & " = " & it.value).join(", ") & "}"
    if objName in e.customTypes:
      "_make(" & objExpr & ", " & overridesExpr & ", \"" & objName & "\")"
    else:
      "_make(" & objExpr & ", " & overridesExpr & ")"

# --- exports: handled at module level, skip in expression context ---
exprHandlers["exports"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  discard e.emitExpr(vals, pos)  # consume the block arg
  "nil"

# ---------------------------------------------------------------------------
# Statement-specific handlers (where stmt behavior differs from expr)
# ---------------------------------------------------------------------------

# break — no expression form, only valid as statement
stmtHandlers["break"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  e.ln("break")

# assert — statement-only; no expression handler exists
stmtHandlers["assert"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  let arg = e.emitExpr(vals, pos)
  e.ln("assert(" & arg & ")")

# error — as statement, raise tagged error table
stmtHandlers["error"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  let kind = e.emitExpr(vals, pos)
  let msg = e.emitExpr(vals, pos)
  let data = e.emitExpr(vals, pos)
  e.ln("error({kind = " & kind & ", msg = " & msg & ", data = " & data & "})")

# exports — as statement, skip the block arg silently (no output)
stmtHandlers["exports"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  if pos < vals.len and vals[pos].kind == vkBlock:
    pos += 1  # skip the block arg

# remove — as statement, emit directly without IIFE wrapper
stmtHandlers["remove"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  let blk = e.emitExpr(vals, pos)
  let idx = e.emitExpr(vals, pos)
  e.ln("table.remove(" & blk & ", " & idx & ")")

# insert — as statement, emit directly without IIFE wrapper
stmtHandlers["insert"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  let blk = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  let idx = e.emitExpr(vals, pos)
  e.ln("table.insert(" & blk & ", " & idx & ", " & val_expr & ")")

# scope — statement with block scoping and locals save/restore
stmtHandlers["scope"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    e.ln("do")
    let savedLocals = e.locals
    e.locals = initHashSet[string]()
    e.indent += 1
    e.emitBlock(blk)
    e.indent -= 1
    e.locals = savedLocals
    e.ln("end")

proc isInfixOp(val: KtgValue): bool =
  val.kind == vkOp or
    (val.kind == vkWord and val.wordKind == wkWord and val.wordName in ["and", "or"])

proc isNumericExpr(vals: seq[KtgValue], pos: int): bool =
  ## Peek at AST to determine if the expression at pos will produce a number.
  if pos >= vals.len: return false
  let v = vals[pos]
  case v.kind
  of vkInteger, vkFloat, vkMoney: return true
  of vkParen:
    for pv in v.parenVals:
      if pv.kind == vkOp: return true
    return false
  of vkWord:
    if v.wordKind == wkWord:
      if pos + 1 < vals.len and isInfixOp(vals[pos + 1]):
        let opName = if vals[pos + 1].kind == vkOp: vals[pos + 1].opSymbol
                     else: vals[pos + 1].wordName
        if opName in ["+", "-", "*", "/", "%"]: return true
      if v.wordName in ["length", "negate", "abs", "round", "round/down",
                         "round/up", "random/int", "random/int/range"]:
        return true
  else: discard
  if pos + 1 < vals.len and vals[pos + 1].kind == vkOp:
    let opSym = vals[pos + 1].opSymbol
    if opSym in ["+", "-", "*", "/", "%"]: return true
  false

# Natives with known sequence-type return values
const StringReturnNatives = [
  "uppercase", "lowercase", "trim", "rejoin", "rejoin/with",
  "char", "join", "to", "pad"  # pad works on both, return same type — tracked separately
]
const BlockReturnNatives = [
  "split", "words", "keys", "values", "reduce", "copy"
]

proc inferSeqType(e: LuaEmitter, vals: seq[KtgValue], pos: int): SeqType =
  ## Determine the sequence type (string or block) of the expression at vals[pos].
  ## Returns stUnknown when the type cannot be determined at compile time.
  if pos >= vals.len: return stUnknown
  let v = vals[pos]
  case v.kind
  of vkString: return stString
  of vkBlock: return stBlock
  of vkParen:
    var pp = 0
    return inferSeqType(e, v.parenVals, pp)
  of vkWord:
    if v.wordKind != wkWord: return stUnknown
    let name = v.wordName
    let lname = luaName(name)
    # Known variable
    if lname in e.varSeqTypes:
      return e.varSeqTypes[lname]
    # Function with known return type
    if name in e.funcReturnTypes:
      let rt = e.funcReturnTypes[name]
      if rt == "string!": return stString
      if rt == "block!": return stBlock
    # Known string-returning native
    if name in StringReturnNatives: return stString
    # Known block-returning native
    if name in BlockReturnNatives: return stBlock
    # reverse/sort/subset/insert/remove return same type as first arg
    if name in ["reverse", "sort", "subset", "insert", "remove"]:
      return inferSeqType(e, vals, pos + 1)
    return stUnknown
  else: return stUnknown

proc luaOp(op: string): string =
  case op
  of "=", "==": "=="
  of "<>": "~="
  of "%": "%"
  of "and": "and"
  of "or": "or"
  else: op  # +, -, *, /, <, >, <=, >= are the same

proc luaPrec(op: string): int =
  ## Lua operator precedence (higher = binds tighter).
  case op
  of "or": 1
  of "and": 2
  of "<", ">", "<=", ">=", "~=", "==": 3
  of "..": 4
  of "+", "-": 5
  of "*", "/", "%", "//": 6
  of "^": 7
  else: 5

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

proc allLuaParams(spec: ParsedFuncSpec): seq[string] =
  ## Full Lua param list: regular params + refinement flags + refinement params.
  for p in spec.params:
    result.add(luaName(p.name))
  for r in spec.refinements:
    result.add(luaName(r.name))
    for rp in r.params:
      result.add(luaName(rp.name))

# ---------------------------------------------------------------------------
# Emit function definition
# ---------------------------------------------------------------------------

proc emitFuncDef(e: var LuaEmitter, specBlock, bodyBlock: seq[KtgValue]): string =
  ## Parse a function spec [a b] and body [...] into a Lua function expression.
  let spec = parseFuncSpec(specBlock)
  let params = spec.allLuaParams()

  let paramStr = params.join(", ")
  var funcStr = "function(" & paramStr & ")\n"

  # Save and reset locals for the new function scope
  let savedLocals = e.locals
  let savedVarTypes = e.varTypes
  let savedSafeVars = e.concatSafeVars
  let savedSeqTypes = e.varSeqTypes
  e.locals = initHashSet[string]()
  # Parameters are locals in the function scope, and potentially callable
  for p in params:
    e.locals.incl(p)
    if p notin e.bindings:
      e.bindings[p] = BindingInfo(arity: -1, isFunction: false, isUnknown: true,
                                   isParam: true, returnArity: -1)
  # Register typed parameters for field-aware rejoin and concat-safe tracking
  for ps in spec.params:
    if ps.typeName.len > 0:
      var typeName = ps.typeName.toLower
      if typeName.endsWith("!"):
        typeName = typeName[0 ..< typeName.len - 1]
      let kebab = typeName.replace("_", "-")
      if kebab in e.objectFields:
        e.varTypes[ps.name] = kebab
      if ps.typeName in SafeConcatTypes:
        e.concatSafeVars.incl(luaName(ps.name))
      if ps.typeName == "string!":
        e.varSeqTypes[luaName(ps.name)] = stString
      elif ps.typeName == "block!":
        e.varSeqTypes[luaName(ps.name)] = stBlock

  e.indent += 1
  # Emit body — last expression is implicit return
  let bodyStr = withCapture(e):
    e.emitBody(bodyBlock, asReturn = true)
  e.indent -= 1

  # Restore outer locals and varTypes (bindings are intentionally kept — prescan is global)
  e.locals = savedLocals
  e.varTypes = savedVarTypes
  e.concatSafeVars = savedSafeVars
  e.varSeqTypes = savedSeqTypes

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
    if bodyVals.len <= 3:  # simple expression: emit directly
      var bpos = 0
      let expr = e.emitExpr(bodyVals, bpos)
      e.ln("_collect_r[#_collect_r+1] = " & expr)
    else:
      e.ln("_collect_r[#_collect_r+1] = (function()")
      e.indent += 1
      e.emitBlock(bodyVals, asReturn = true)
      e.indent -= 1
      e.ln("end)()")
  of "fold":
    # Body result becomes new accumulator
    if bodyVals.len <= 3:
      var bpos = 0
      let expr = e.emitExpr(bodyVals, bpos)
      e.ln("_fold_acc = " & expr)
    else:
      e.ln("_fold_acc = (function()")
      e.indent += 1
      e.emitBlock(bodyVals, asReturn = true)
      e.indent -= 1
      e.ln("end)()")
  of "partition":
    # Body is predicate - element goes to true or false bucket.
    # Inline the predicate when it's a single expression; wrap otherwise.
    if bodyVals.len <= 3:
      var bpos = 0
      let predExpr = e.emitExpr(bodyVals, bpos)
      e.ln("if " & predExpr & " then")
    else:
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
        # Infer type before emitting series (consumes pos)
        let seriesType = e.inferSeqType(blk, pos)
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
            e.ln("local _fold_s = " & series)
            e.ln("local _fold_acc = _fold_s[1]")
            let accVar = if vars.len >= 2: vars[0] else: iterVar
            let elemVar = if vars.len >= 2: vars[1] else: iterVar
            e.ln("for _i = 2, #_fold_s do")
            e.indent += 1
            e.ln("local " & elemVar & " = _fold_s[_i]")
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
            let iv = if vars.len > 0: vars[0] else: "_"
            if seriesType == stString:
              e.ln("for _i = 1, #" & series & " do")
              e.indent += 1
              if vars.len > 0:
                e.ln("local " & iv & " = " & series & ":sub(_i, _i)")
              if guard.len > 0:
                e.ln("if " & guard & " then")
                e.indent += 1
                e.emitLoopBody(blk[pos].blockVals, refinement, iv)
                e.indent -= 1
                e.ln("end")
              else:
                e.emitLoopBody(blk[pos].blockVals, refinement, iv)
              e.indent -= 1
              e.ln("end")
            else:
              let varStr = if vars.len > 0: "_, " & vars[0] else: "_"
              e.ln("for " & varStr & " in ipairs(" & series & ") do")
              e.indent += 1
              if guard.len > 0:
                e.ln("if " & guard & " then")
                e.indent += 1
                e.emitLoopBody(blk[pos].blockVals, refinement, iv)
                e.indent -= 1
                e.ln("end")
              else:
                e.emitLoopBody(blk[pos].blockVals, refinement, iv)
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
# Shared pattern matching: build conditions and bindings from a pattern
# ---------------------------------------------------------------------------

proc buildPatternMatch(e: var LuaEmitter, pattern: seq[KtgValue], valueExpr: string,
                       conditions: var seq[string],
                       bindings: var seq[(string, string)]) =
  ## Recursively build match conditions and capture bindings for a pattern.
  ## Works for both single-element and multi-element (destructuring) patterns.
  if pattern.len == 1:
    let p = pattern[0]
    case p.kind
    of vkInteger, vkFloat, vkString, vkLogic, vkNone, vkMoney:
      conditions.add(valueExpr & " == " & emitLiteral(p))
    of vkType:
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
        bindings.add((luaName(p.wordName), valueExpr))
      elif p.wordKind == wkLitWord:
        conditions.add(valueExpr & " == \"" & p.wordName & "\"")
    of vkParen:
      # Computed match — emit the paren contents as an expression
      var ppos = 0
      let computedExpr = e.emitExpr(p.parenVals, ppos)
      conditions.add(valueExpr & " == " & computedExpr)
    else:
      discard
  else:
    # Multi-element pattern — destructuring match against a table
    conditions.add("type(" & valueExpr & ") == \"table\"")
    conditions.add("#" & valueExpr & " == " & $pattern.len)
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
        if p.wordKind == wkWord and p.wordName == "_":
          discard
        elif p.wordKind == wkWord:
          bindings.add((luaName(p.wordName), elemExpr))
        elif p.wordKind == wkLitWord:
          conditions.add(elemExpr & " == \"" & p.wordName & "\"")
      of vkBlock:
        # Nested block destructuring — recurse
        e.buildPatternMatch(p.blockVals, elemExpr, conditions, bindings)
      of vkParen:
        var ppos = 0
        let computedExpr = e.emitExpr(p.parenVals, ppos)
        conditions.add(elemExpr & " == " & computedExpr)
      else:
        discard

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

    # default handler
    if current.kind == vkWord and current.wordKind == wkWord and
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
    var bindings: seq[(string, string)] = @[]
    e.buildPatternMatch(pattern, valueExpr, conditions, bindings)

    if guardExpr.len > 0:
      conditions.add(guardExpr)

    let condStr = if conditions.len > 0: conditions.join(" and ") else: ""
    if condStr.len == 0 and not first:
      e.ln("else")
    else:
      let keyword = if first: "if" else: "elseif"
      let cond = if condStr.len > 0: condStr else: "true"
      e.ln(keyword & " " & cond & " then")
    e.indent += 1

    # Emit bindings as locals
    for (name, expr) in bindings:
      e.ln("local " & name & " = " & expr)

    # Save locals before branch — Lua's local is block-scoped
    let savedLocals = e.locals
    if asReturn:
      e.emitBlock(handler, asReturn = true)
    else:
      e.emitBlock(handler)
    e.locals = savedLocals
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

    if current.kind == vkWord and current.wordKind == wkWord and
       current.wordName == "default":
      pos += 1
      if pos < rulesBlock.len and rulesBlock[pos].kind == vkBlock:
        if first:
          discard
        else:
          code &= baseIndent & "  else\n"
        let savedIndent = e.indent
        e.indent = e.indent + 2
        let captured = withCapture(e):
          e.emitBody(rulesBlock[pos].blockVals, asReturn = true)
        code &= captured
        e.indent = savedIndent
        pos += 1
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
    e.buildPatternMatch(pattern, valueExpr, conditions, bindings)

    if guardExpr.len > 0:
      conditions.add(guardExpr)

    let condStr = if conditions.len > 0: conditions.join(" and ") else: ""
    if condStr.len == 0 and not first:
      # Unconditional pattern after other branches - emit as else
      code &= baseIndent & "  else\n"
    else:
      let keyword = if first: "if" else: "elseif"
      let cond = if condStr.len > 0: condStr else: "true"
      code &= baseIndent & "  " & keyword & " " & cond & " then\n"

    # Emit bindings
    for (name, expr) in bindings:
      code &= baseIndent & "    local " & name & " = " & expr & "\n"

    # Emit handler body with return — save/restore locals for Lua block scoping
    let savedIndent = e.indent
    let savedLocals = e.locals
    e.indent = e.indent + 2
    let captured = withCapture(e):
      e.emitBody(handler, asReturn = true)
    code &= captured
    e.indent = savedIndent
    e.locals = savedLocals
    first = false

  if not first:
    code &= baseIndent & "  end\n"
  code &= baseIndent & "end)()"
  result = code

# ---------------------------------------------------------------------------
# Emit match as hoisted assignment (no IIFE)
# ---------------------------------------------------------------------------

proc emitMatchHoisted(e: var LuaEmitter, varName: string, valueExpr: string,
                      rulesBlock: seq[KtgValue]) =
  ## match value [...rules...] assigned to varName.
  ## Emits: local varName; if ... varName = expr elseif ... end
  var pos = 0
  var first = true

  while pos < rulesBlock.len:
    let current = rulesBlock[pos]

    # default handler
    if current.kind == vkWord and current.wordKind == wkWord and
       current.wordName == "default":
      pos += 1
      if pos < rulesBlock.len and rulesBlock[pos].kind == vkBlock:
        let handler = rulesBlock[pos].blockVals
        pos += 1
        if first:
          # Only default branch - just emit the body as assignment
          e.indent += 1
          let savedLocals = e.locals
          if handler.len <= 3:
            var hpos = 0
            let expr = e.emitExpr(handler, hpos)
            e.indent -= 1
            e.ln(varName & " = " & expr)
          else:
            e.emitBlock(handler)
            e.indent -= 1
          e.locals = savedLocals
        else:
          e.ln("else")
          e.indent += 1
          let savedLocals = e.locals
          if handler.len <= 3:
            var hpos = 0
            let expr = e.emitExpr(handler, hpos)
            e.ln(varName & " = " & expr)
          else:
            e.emitBlock(handler)
          e.locals = savedLocals
          e.indent -= 1
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
    e.buildPatternMatch(pattern, valueExpr, conditions, bindings)

    if guardExpr.len > 0:
      conditions.add(guardExpr)

    let condStr = if conditions.len > 0: conditions.join(" and ") else: ""
    if condStr.len == 0 and not first:
      e.ln("else")
    else:
      let keyword = if first: "if" else: "elseif"
      let cond = if condStr.len > 0: condStr else: "true"
      e.ln(keyword & " " & cond & " then")
    e.indent += 1

    # Emit bindings as locals
    for (name, expr) in bindings:
      e.ln("local " & name & " = " & expr)

    # Emit handler body - last expression assigned to varName
    let savedLocals = e.locals
    if handler.len <= 3:
      var hpos = 0
      let expr = e.emitExpr(handler, hpos)
      e.ln(varName & " = " & expr)
    else:
      e.emitBlock(handler)
    e.locals = savedLocals
    e.indent -= 1
    first = false

  if not first:
    e.ln("end")

# ---------------------------------------------------------------------------
# Emit either as expression
# ---------------------------------------------------------------------------

proc emitEitherExpr(e: var LuaEmitter, cond: string, trueBlock, falseBlock: seq[KtgValue]): string =
  ## Emit either as expression using IIFE to correctly handle all values
  ## including false and nil in the true branch.
  let baseIndent = e.pad
  var code = "(function()\n"
  code &= baseIndent & "  if " & cond & " then\n"
  let savedIndent = e.indent
  e.indent = e.indent + 2
  let trueCapture = withCapture(e):
    e.emitBody(trueBlock, asReturn = true)
  code &= trueCapture
  e.indent = savedIndent
  code &= baseIndent & "  else\n"
  e.indent = e.indent + 2
  let falseCapture = withCapture(e):
    e.emitBody(falseBlock, asReturn = true)
  code &= falseCapture
  e.indent = savedIndent
  code &= baseIndent & "  end\n"
  code &= baseIndent & "end)()"
  result = code


# ---------------------------------------------------------------------------
# Emit attempt dialect as pcall chain
# ---------------------------------------------------------------------------

type
  AttemptStepKind = enum
    askThen, askWhen

  AttemptStep = object
    kind: AttemptStepKind
    body: seq[KtgValue]

proc emitBodyOneline(e: var LuaEmitter, body: seq[KtgValue]): string =
  ## Emit a single-expression body as a direct Lua expression.
  ## Returns empty string if the body isn't expressible as a single expression.
  if body.len == 0:
    return "nil"
  var bpos = 0
  let expr = e.emitExpr(body, bpos)
  if bpos >= body.len:
    return expr
  # Multi-expression body — caller should use IIFE
  return ""

proc emitAttemptExpr(e: var LuaEmitter, blk: seq[KtgValue]): string =
  ## Emit an attempt pipeline as a pcall-based expression.
  ## attempt [source [...] then [...] when [...] catch 'kind [...] fallback [...] retries N]
  var sourceBody: seq[KtgValue] = @[]
  var pipelineSteps: seq[AttemptStep] = @[]
  var catches: seq[(string, seq[KtgValue])] = @[]
  var fallbackBody: seq[KtgValue] = @[]
  var retryCount = 0
  var hasSource = false
  var hasFallback = false

  # Parse the pipeline block, preserving step order for then/when interleaving
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
          pipelineSteps.add(AttemptStep(kind: askThen, body: blk[ppos].blockVals))
          ppos += 1
      of "when":
        ppos += 1
        if ppos < blk.len and blk[ppos].kind == vkBlock:
          pipelineSteps.add(AttemptStep(kind: askWhen, body: blk[ppos].blockVals))
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
          hasFallback = true
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
    compileError("attempt without source", "sourceless attempt pipelines require runtime closures; provide a source block or restructure", 0)

  let baseIndent = e.pad
  let savedIndent = e.indent
  var code = "(function()\n"

  # Optional retry loop wrapper
  var loopIndentLvl = savedIndent + 1
  if retryCount > 0:
    code &= baseIndent & "  for _attempt = 1, " & $(retryCount + 1) & " do\n"
    loopIndentLvl = savedIndent + 2

  let loopIndent = repeat("  ", loopIndentLvl)
  let innerIndent = repeat("  ", loopIndentLvl + 1)

  # Build the pcall body: source, then steps, when guards, return it
  e.indent = loopIndentLvl + 1
  var pcallBody = ""

  # Source: local it = <expr>
  let srcOneline = e.emitBodyOneline(sourceBody)
  if srcOneline.len > 0:
    pcallBody &= innerIndent & "local it = " & srcOneline & "\n"
  else:
    # Multi-expression source: use inner function
    let srcCode = withCapture(e):
      e.emitBlock(sourceBody, asReturn = true)
    pcallBody &= innerIndent & "local it = (function()\n"
    pcallBody &= srcCode
    pcallBody &= innerIndent & "end)()\n"

  # Walk steps in order
  for step in pipelineSteps:
    case step.kind
    of askThen:
      let oneline = e.emitBodyOneline(step.body)
      if oneline.len > 0:
        pcallBody &= innerIndent & "it = " & oneline & "\n"
      else:
        let body = withCapture(e):
          e.emitBlock(step.body, asReturn = true)
        pcallBody &= innerIndent & "it = (function()\n"
        pcallBody &= body
        pcallBody &= innerIndent & "end)()\n"
    of askWhen:
      let guard = e.emitBodyOneline(step.body)
      if guard.len > 0:
        pcallBody &= innerIndent & "if not (" & guard & ") then return nil end\n"
      else:
        let body = withCapture(e):
          e.emitBlock(step.body, asReturn = true)
        pcallBody &= innerIndent & "if not ((function()\n"
        pcallBody &= body
        pcallBody &= innerIndent & "end)()) then return nil end\n"

  pcallBody &= innerIndent & "return it\n"

  # Emit the pcall wrapper
  code &= loopIndent & "local _ok, it = pcall(function()\n"
  code &= pcallBody
  code &= loopIndent & "end)\n"
  code &= loopIndent & "if _ok then return it end\n"

  # Error path
  let isLastAttempt = if retryCount > 0: "_attempt >= " & $(retryCount + 1) else: "true"
  if retryCount > 0:
    code &= loopIndent & "if " & isLastAttempt & " then\n"
    e.indent = loopIndentLvl + 1
  else:
    e.indent = loopIndentLvl

  let errIndent = repeat("  ", e.indent)

  # Normalize error — only needed when we'll inspect the kind or bind error msg
  let needsErrNorm = catches.len > 0 or hasFallback
  if needsErrNorm:
    if catches.len > 0:
      code &= errIndent & "local _ek = type(it) == \"table\" and it.kind or \"runtime\"\n"
    code &= errIndent & "local _em = type(it) == \"table\" and it.msg or tostring(it)\n"

  # Catch dispatch
  for (kind, body) in catches:
    code &= errIndent & "if _ek == \"" & kind & "\" then\n"
    e.indent += 1
    let catchBody = withCapture(e):
      e.ln("local error = _em")
      let oneline = e.emitBodyOneline(body)
      if oneline.len > 0:
        e.ln("return " & oneline)
      else:
        e.emitBlock(body, asReturn = true)
    code &= catchBody
    e.indent -= 1
    code &= errIndent & "end\n"

  # Fallback
  if hasFallback:
    code &= errIndent & "local error = _em\n"
    let fbCode = withCapture(e):
      let oneline = e.emitBodyOneline(fallbackBody)
      if oneline.len > 0:
        e.ln("return " & oneline)
      else:
        e.emitBlock(fallbackBody, asReturn = true)
    code &= fbCode
  else:
    code &= errIndent & "error(it)\n"

  if retryCount > 0:
    code &= loopIndent & "end\n"
    code &= baseIndent & "  end\n"

  code &= baseIndent & "end)()"
  e.indent = savedIndent
  result = code


# ---------------------------------------------------------------------------
# Core expression emitter — returns a Lua expression string
# ---------------------------------------------------------------------------

proc emitExpr(e: var LuaEmitter, vals: seq[KtgValue], pos: var int,
              primary: bool = false): string =
  ## Emit the next expression from vals starting at pos. Returns a Lua
  ## expression string and advances pos past the consumed values.
  ## When primary=false (default), greedily consumes infix operators.
  ## When primary=true, emits only the primary expression (no infix chain).
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
  # (f x) where f is unknown param = function call. (expr op expr) = grouping.
  of vkParen:
    let pvals = val.parenVals
    # Check for (f x) pattern: unknown param, not a path, next token not infix
    let isParamCall = pvals.len >= 2 and
      pvals[0].kind == vkWord and pvals[0].wordKind == wkWord and
      not pvals[0].wordName.contains('/') and
      not isInfixOp(pvals[1]) and
      (let info = e.getBinding(pvals[0].wordName); info.isParam)
    if isParamCall:
      let headName = pvals[0].wordName
      var ppos = 1
      var args: seq[string] = @[]
      while ppos < pvals.len:
        args.add(e.emitExpr(pvals, ppos))
      result = "(" & e.resolvedName(headName) & "(" & args.join(", ") & "))"
    else:
      var ppos = 0
      let inner = e.emitExpr(pvals, ppos)
      # Kintsugi parens group evaluation order. Lua has operator
      # precedence, Kintsugi does not — so we must preserve parens
      # whenever the inner expression contains an infix operator that
      # Lua could otherwise re-associate. Dropping parens around a
      # subtraction inside a multiplication (e.g. `(b - a) * t`) would
      # silently change the result. Single-token or pure-call paren
      # groups still drop their parens.
      var hasInfix = false
      for pv in pvals:
        if isInfixOp(pv):
          hasInfix = true
          break
      if ppos < pvals.len or hasInfix:
        result = "(" & inner & ")"
      else:
        result = inner

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
      if val.wordName == "parse":
        compileError("@parse", "the parse dialect is interpreter-only; restructure to avoid it in compiled code", val.line)
      if val.wordName == "compose" or val.wordName.startsWith("compose/"):
        compileError("@compose", "@compose is a compile-time feature; use it inside @macro or @preprocess", val.line)
      # Other meta-words (@type, etc.) are erased in compiled output
      result = "nil"

    of wkWord:
      let name = val.wordName

      # --- Dispatch table lookup (handlers registered above) ---
      # Skip if the name has been user-assigned as a value (prescan found name: expr)
      let userAssigned = name in e.bindings and
        not e.bindings[name].isFunction and not e.bindings[name].isUnknown
      if name in exprHandlers and not userAssigned:
        result = exprHandlers[name](e, vals, pos)

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
            e.indent += 2
            handlerBody = withCapture(e):
              e.emitBody(hblk, asReturn = true)
          e.indent += 1
          let bodyStr = withCapture(e):
            e.emitBody(blk, asReturn = true)
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
      # --- Dialect refinement paths (must come before generic path handler) ---
      elif name.startsWith("loop/") and name.split('/')[1] in ["collect", "fold", "partition"]:
        let refinement = name.split('/')[1]
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          e.indent += 1
          let loopCode = withCapture(e):
            let resultVar = e.emitLoop(blk, refinement)
            e.ln("return " & resultVar)
          e.indent -= 1
          result = "(function()\n" & loopCode & e.pad & "end)()"
        else:
          result = "nil"

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


      # --- if: condition block ---
      elif name == "if":
        let cond = e.emitExpr(vals, pos)
        if pos < vals.len and vals[pos].kind == vkBlock:
          let bodyBlock = vals[pos].blockVals
          pos += 1
          # Try `cond and expr or nil` when the body is a single expression
          # with a literal-truthy result. Only literal-shaped truthy values
          # are safe; variables/calls could evaluate to false/nil.
          var inlined = false
          if bodyBlock.len <= 3:
            var bpos = 0
            let bodyExpr = e.emitExpr(bodyBlock, bpos)
            if bpos >= bodyBlock.len:
              let safe = bodyExpr.startsWith("{") or
                         (bodyExpr.startsWith("\"") and bodyExpr != "\"\"") or
                         (bodyExpr.len > 0 and bodyExpr[0] in {'1'..'9'})
              if safe:
                result = "(" & cond & " and " & bodyExpr & " or nil)"
                inlined = true
          if not inlined:
            e.indent += 1
            let bodyOut = withCapture(e):
              e.emitBody(bodyBlock, asReturn = true)
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
        # Short-branch optimization: when both branches are single
        # expressions and the true-branch expression is literal-safe
        # (never false/nil), emit `cond and trueExpr or falseExpr`.
        var inlined = false
        if trueBlock.len <= 3 and falseBlock.len <= 3:
          var tpos = 0
          let trueExpr = e.emitExpr(trueBlock, tpos)
          var fpos = 0
          let falseExpr = e.emitExpr(falseBlock, fpos)
          if tpos >= trueBlock.len and fpos >= falseBlock.len:
            let truthySafe = trueExpr.startsWith("{") or
                             (trueExpr.startsWith("\"") and trueExpr != "\"\"") or
                             (trueExpr.len > 0 and trueExpr[0] in {'1'..'9'}) or
                             (trueExpr.len > 1 and trueExpr[0] == '-' and
                              trueExpr[1] in {'1'..'9'})
            if truthySafe:
              result = "(" & cond & " and " & trueExpr & " or " & falseExpr & ")"
              inlined = true
        if not inlined:
          result = e.emitEitherExpr(cond, trueBlock, falseBlock)

      # --- function definition ---
      elif name == "function":
        if pos + 1 < vals.len and vals[pos].kind == vkBlock and vals[pos + 1].kind == vkBlock:
          let specBlock = vals[pos].blockVals
          let bodyBlock = vals[pos + 1].blockVals
          pos += 2
          result = e.emitFuncDef(specBlock, bodyBlock)
        else:
          result = "nil"

      elif name == "does":
        if pos < vals.len and vals[pos].kind == vkBlock:
          let bodyBlock = vals[pos].blockVals
          pos += 1
          result = e.emitFuncDef(@[], bodyBlock)
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
          let savedLocals = e.locals
          e.locals = initHashSet[string]()
          e.indent += 1
          let bodyStr = withCapture(e):
            e.emitBlock(blk, asReturn = true)
          e.locals = savedLocals
          e.indent -= 1
          result = "(function()\n" & bodyStr & e.pad & "end)()"
        else:
          result = "nil"

      # --- loop dialect ---
      elif name == "loop":
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          let loopCode = withCapture(e):
            discard e.emitLoop(blk)
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

      elif name == "rejoin/with":
        # rejoin/with [block] delimiter — join with separator
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          let delim = e.emitExpr(vals, pos)
          var parts: seq[string] = @[]
          var bpos = 0
          while bpos < blk.len:
            let elem = e.emitExpr(blk, bpos)
            if elem.startsWith("\""):
              parts.add(elem)
            else:
              parts.add("tostring(" & elem & ")")
          result = "table.concat({" & parts.join(", ") & "}, " & delim & ")"
        else:
          let arg = e.emitExpr(vals, pos)
          let delim = e.emitExpr(vals, pos)
          result = "table.concat(" & arg & ", " & delim & ")"

      elif name == "rejoin":
        # rejoin on a block — concatenate with .. operator
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          var parts: seq[string] = @[]
          var bpos = 0
          while bpos < blk.len:
            # Check AST for typed field access or safe variable before emitting
            var fieldSafe = false
            if bpos < blk.len and blk[bpos].kind == vkWord and
               blk[bpos].wordKind == wkWord:
              let wordName = blk[bpos].wordName
              if "/" in wordName:
                let pathParts = wordName.split("/")
                if pathParts.len == 2:
                  let varName = luaName(pathParts[0])
                  let fieldName = luaName(pathParts[1])
                  fieldSafe = e.isFieldSafeForConcat(varName, fieldName)
              else:
                # Bare variable - check if it's known safe (typed string/number param)
                fieldSafe = luaName(wordName) in e.concatSafeVars
            # Also check for paren groups containing arithmetic or safe func calls
            if not fieldSafe and bpos < blk.len and blk[bpos].kind == vkParen:
              let pvals = blk[bpos].parenVals
              # Arithmetic ops make it numeric
              for pv in pvals:
                if pv.kind == vkOp or
                   (pv.kind == vkWord and pv.wordKind == wkWord and
                    pv.wordName in ["+", "-", "*", "/"]):
                  fieldSafe = true
                  break
              # Function call with known safe return type
              if not fieldSafe and pvals.len >= 1 and pvals[0].kind == vkWord and
                 pvals[0].wordKind == wkWord and
                 pvals[0].wordName in e.funcReturnTypes and
                 e.funcReturnTypes[pvals[0].wordName] in SafeConcatTypes:
                fieldSafe = true
            let elem = e.emitExpr(blk, bpos)
            # Lua's .. auto-coerces numbers. Only wrap types that could error.
            let needsWrap = not (
              fieldSafe or
              elem.startsWith("\"") or          # string literal
              elem.startsWith("(") or           # grouped expr (arithmetic/call)
              (elem.len > 0 and elem[0] in {'0'..'9', '-'})  # number literal
            )
            if needsWrap:
              parts.add("tostring(" & elem & ")")
            else:
              parts.add(elem)
          # Merge adjacent string literals
          var merged: seq[string] = @[]
          for p in parts:
            if merged.len > 0 and merged[^1].endsWith("\"") and p.startsWith("\""):
              merged[^1] = merged[^1][0..^2] & p[1..^1]
            else:
              merged.add(p)
          if merged.len == 1:
            result = merged[0]
          else:
            result = merged.join(" .. ")
        else:
          let arg = e.emitExpr(vals, pos)
          result = "table.concat(" & arg & ")"

      elif name == "find":
        let seqType = e.inferSeqType(vals, pos)
        let series = e.emitExpr(vals, pos)
        let needle = e.emitExpr(vals, pos)
        case seqType
        of stString:
          # Extra parens force Lua to take only first return value (start index).
          result = "(string.find(" & series & ", " & needle & ", 1, true))"
        of stBlock:
          # Scalar needle: inline == loop. Otherwise use _equals helper.
          let isScalar = pos < vals.len + 2  # placeholder; emit inline anyway for blocks
          discard isScalar
          e.useHelper("_equals")
          result = "(function() for i, v in ipairs(" & series & ") do if _equals(v, " & needle & ") then return i end end return nil end)()"
        of stUnknown:
          e.useHelper("_equals")
          result = "(function() " &
                   "if type(" & series & ") == \"string\" then " &
                   "local i = string.find(" & series & ", " & needle & ", 1, true); " &
                   "if i then return i end; return nil " &
                   "else " &
                   "for i, v in ipairs(" & series & ") do if _equals(v, " & needle & ") then return i end end; return nil " &
                   "end " &
                   "end)()"

      elif name == "reverse":
        let seqType = e.inferSeqType(vals, pos)
        let arg = e.emitExpr(vals, pos)
        let a = wrapIfTableCtor(arg)
        case seqType
        of stString:
          result = "string.reverse(" & a & ")"
        of stBlock:
          result = "(function() local _t=" & a & "; local r={}; for i=#_t,1,-1 do r[#r+1]=_t[i] end; return r end)()"
        of stUnknown:
          result = "(function() " &
                   "if type(" & a & ") == \"string\" then return string.reverse(" & a & ") " &
                   "else local _t=" & a & "; local r={}; for i=#_t,1,-1 do r[#r+1]=_t[i] end; return r end " &
                   "end)()"

      # --- try ---
      elif name == "try":
        if pos < vals.len and vals[pos].kind == vkBlock:
          let blk = vals[pos].blockVals
          pos += 1
          e.indent += 1
          let bodyStr = withCapture(e):
            e.emitBody(blk, asReturn = true)
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

      # --- require: compile dependency and emit Lua require() ---
      elif name == "import":
        if pos < vals.len:
          when defined(js):
            discard vals[pos]
            pos += 1
            raise EmitError(msg: "import is not supported in the browser playground")
          else:
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

      # --- Generic function call or variable reference ---
      else:
        let resolvedLua = e.resolvedName(name)
        let info = e.getBinding(name)
        let isMethod = name in e.bindingKinds and e.bindingKinds[name] == bkMethod
        let a = e.arity(name)
        if a >= 0:
          var args: seq[string] = @[]
          for i in 0 ..< a:
            args.add(e.emitExpr(vals, pos, primary = true))
          # Append default refinement args (all false/nil) for non-refinement calls
          if info.refinements.len > 0:
            for r in info.refinements:
              args.add("false")
              for j in 0 ..< r.paramCount:
                args.add("nil")
          if isMethod:
            # obj.method -> obj:method
            let dotPos = resolvedLua.rfind('.')
            let methodLua = resolvedLua[0..<dotPos] & ":" & resolvedLua[dotPos+1..^1]
            result = methodLua & "(" & args.join(", ") & ")"
          else:
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

  # Handle infix chain — left-to-right (Kintsugi has no precedence).
  # Leverage Lua's own precedence: only add parens when Kintsugi's left-to-right
  # order disagrees with Lua's precedence (higher-prec op follows lower-prec op).
  if not primary:
    var lastPrec = int.high  # no prior op = highest (never needs wrapping)
    while pos < vals.len and isInfixOp(vals[pos]):
      let op = vals[pos]
      let opStr = if op.kind == vkOp: luaOp(op.opSymbol) else: luaOp(op.wordName)
      let prec = luaPrec(opStr)
      pos += 1
      let right = e.emitExpr(vals, pos, primary = true)
      # Special case: = none / <> none -> == nil / ~= nil
      if right == "nil" and opStr == "==":
        result = "(" & result & " == nil)"
        lastPrec = prec
      elif right == "nil" and opStr == "~=":
        result = "(" & result & " ~= nil)"
        lastPrec = prec
      elif result == "nil" and opStr == "==":
        result = "(" & right & " == nil)"
        lastPrec = prec
      elif result == "nil" and opStr == "~=":
        result = "(" & right & " ~= nil)"
        lastPrec = prec
      else:
        # Wrap left side only when this op binds tighter in Lua than the
        # previous one — otherwise Lua's precedence already groups correctly.
        if prec > lastPrec:
          result = "(" & result & ")"
        result = result & " " & opStr & " " & right
        lastPrec = prec

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
                            "print", "probe", "assert", "return", "break", "error", "try",
                            "do", "in", "from", "to", "by", "when",
                            "source", "then", "fallback", "retries", "catch", "default"]: break
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
  discard withCapture(e):
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

  # sort/by: hoist to statements, then return
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName in ["sort/by", "sort/with"]:
    let sortKind = lastVal.wordName
    var lpos = 1
    let arr = e.emitExpr(vals, lpos)
    let fnExpr = e.emitExpr(vals, lpos)
    if sortKind == "sort/by":
      e.ln("local _key = " & fnExpr)
      e.ln("table.sort(" & arr & ", function(a, b) return _key(a) < _key(b) end)")
    else:
      e.ln("table.sort(" & arr & ", " & fnExpr & ")")
    e.ln("return " & arr)
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
        # Detect RHS = loop/collect|fold|partition and emit the loop inline
        # rather than letting emitExpr wrap it in an IIFE.
        if pos < vals.len and vals[pos].kind == vkWord and
           vals[pos].wordKind == wkWord and
           vals[pos].wordName.startsWith("loop/"):
          let refinement = vals[pos].wordName.split('/')[1]
          if refinement in ["collect", "fold", "partition"]:
            pos += 1
            if pos < vals.len and vals[pos].kind == vkBlock:
              let blk = vals[pos].blockVals
              pos += 1
              let resultVar = e.emitLoop(blk, refinement)
              e.ln("local " & tmp & " = " & resultVar)
              if names.len > 0:
                var indices: seq[string] = @[]
                for i in 1 .. names.len:
                  indices.add(tmp & "[" & $i & "]")
                e.ln("local " & names.join(", ") & " = " & indices.join(", "))
              if restName.len > 0:
                e.ln("local " & restName & " = {unpack(" & tmp & ", " & $(restAfter + 1) & ")}")
              continue
        # Fallback: generic expression RHS
        let valueExpr = e.emitExpr(vals, pos)
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
        let isMethod = name in e.bindingKinds and e.bindingKinds[name] == bkMethod
        var args: seq[string] = @[]
        for i in 0 ..< a:
          args.add(e.emitExpr(vals, pos))
        if isMethod:
          let dotPos = resolvedLua.rfind('.')
          let methodLua = resolvedLua[0..<dotPos] & ":" & resolvedLua[dotPos+1..^1]
          e.ln(methodLua & "(" & args.join(", ") & ")")
        else:
          e.ln(resolvedLua & "(" & args.join(", ") & ")")
        continue
      elif a == 0:
        let isMethod = name in e.bindingKinds and e.bindingKinds[name] == bkMethod
        if isMethod:
          let dotPos = resolvedLua.rfind('.')
          let methodLua = resolvedLua[0..<dotPos] & ":" & resolvedLua[dotPos+1..^1]
          e.ln(methodLua & "()")
        else:
          e.ln(resolvedLua & "()")
        continue
      else:
        # const or alias — emit bare
        e.ln(resolvedLua)
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
                   elif isPath: ""            # path access: no 'local'
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
          let spec = parseFuncSpec(specBlock)
          let params = spec.allLuaParams()

          let isOverride = rawName in e.bindingKinds and e.bindingKinds[rawName] == bkOverride
          if isOverride:
            e.ln("function " & name & "(" & params.join(", ") & ")")
          elif isPath or isBound:
            e.ln(name & " = function(" & params.join(", ") & ")")
          else:
            e.ln(prefix & "function " & name & "(" & params.join(", ") & ")")
          let savedLocals = e.locals
          let savedVarTypes = e.varTypes
          let savedSafeVars = e.concatSafeVars
          let savedSeqTypes = e.varSeqTypes
          # Inherit outer-scope names so set-words in the function body
          # that match an enclosing name thread through instead of
          # shadowing (matches interpreter write-through semantics).
          # moduleNames covers names declared later in source order than
          # this function — the interpreter sees them via scope chain at
          # call time, so the emitter must too.
          e.locals = savedLocals
          for n in e.moduleNames:
            e.locals.incl(n)
          for p in params:
            e.locals.incl(p)
            if p notin e.bindings:
              e.bindings[p] = BindingInfo(arity: -1, isFunction: false, isUnknown: true,
                                           isParam: true, returnArity: -1)
          # Register typed parameters for field-aware rejoin and concat-safe tracking
          for ps in spec.params:
            if ps.typeName.len > 0:
              var typeName = ps.typeName.toLower
              if typeName.endsWith("!"):
                typeName = typeName[0 ..< typeName.len - 1]
              let kebab = typeName.replace("_", "-")
              if kebab in e.objectFields:
                e.varTypes[ps.name] = kebab
              if ps.typeName in SafeConcatTypes:
                e.concatSafeVars.incl(luaName(ps.name))
              if ps.typeName == "string!":
                e.varSeqTypes[luaName(ps.name)] = stString
              elif ps.typeName == "block!":
                e.varSeqTypes[luaName(ps.name)] = stBlock
          e.indent += 1
          e.emitBody(bodyBlock, asReturn = not (isPath or isBound or isOverride))
          e.indent -= 1
          e.locals = savedLocals
          e.varTypes = savedVarTypes
          e.concatSafeVars = savedSafeVars
          e.varSeqTypes = savedSeqTypes
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

      # Check if RHS is an object definition — skip if all make calls can inline
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName == "object":
        let kebab = rawName.toLower.replace("_", "-")
        if kebab in e.objectFields:
          pos += 1  # skip "object"
          if pos < vals.len and vals[pos].kind == vkBlock:
            pos += 1  # skip spec block
          continue

      # Check if RHS is sort/by or sort/with — emit hoisted (no IIFE)
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName in ["sort/by", "sort/with"]:
        let sortKind = vals[pos].wordName
        pos += 1
        let arr = e.emitExpr(vals, pos)
        let fnExpr = e.emitExpr(vals, pos)
        if sortKind == "sort/by":
          e.ln("local _key = " & fnExpr)
          e.ln("table.sort(" & arr & ", function(a, b) return _key(a) < _key(b) end)")
        else:
          e.ln("table.sort(" & arr & ", " & fnExpr & ")")
        e.ln(prefix & name & " = " & arr)
        continue

      # Check if RHS is a loop refinement — emit hoisted (no IIFE)
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName.startsWith("loop/"):
        let refinement = vals[pos].wordName.split('/')[1]
        if refinement in ["collect", "fold", "partition"]:
          pos += 1
          if pos < vals.len and vals[pos].kind == vkBlock:
            let blk = vals[pos].blockVals
            pos += 1
            let resultVar = e.emitLoop(blk, refinement)
            e.ln(prefix & name & " = " & resultVar)
            continue

      # Check if RHS is a match expression — emit as hoisted if/elseif
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName == "match":
        pos += 1
        let valueExpr = e.emitExpr(vals, pos)
        if pos < vals.len and vals[pos].kind == vkBlock:
          let rulesBlock = vals[pos].blockVals
          pos += 1
          if prefix.len > 0:
            e.ln(prefix & name)
          e.emitMatchHoisted(name, valueExpr, rulesBlock)
          continue

      # Check if RHS is an either expression — emit as hoisted if/else
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
        # Simple case: single expression in each branch
        if trueBlock.len <= 3 and falseBlock.len <= 3:
          var tpos = 0
          let trueExpr = e.emitExpr(trueBlock, tpos)
          var fpos = 0
          let falseExpr = e.emitExpr(falseBlock, fpos)
          if prefix.len > 0:
            e.ln(prefix & name)
          e.ln("if " & cond & " then")
          e.indent += 1
          e.ln(name & " = " & trueExpr)
          e.indent -= 1
          e.ln("else")
          e.indent += 1
          e.ln(name & " = " & falseExpr)
          e.indent -= 1
          e.ln("end")
        else:
          let eitherExpr = e.emitEitherExpr(cond, trueBlock, falseBlock)
          e.ln(prefix & name & " = " & eitherExpr)
        continue

      # Regular assignment (with -> chain support)
      # Infer sequence type of RHS for tracking
      let rhsSeqType = e.inferSeqType(vals, pos)
      if rhsSeqType != stUnknown:
        e.varSeqTypes[name] = rhsSeqType
      # Peek ahead to infer if RHS is numeric — mark variable as concat-safe
      if isNumericExpr(vals, pos):
        e.concatSafeVars.incl(name)
      elif pos < vals.len and vals[pos].kind == vkWord and
           vals[pos].wordKind == wkWord and "/" in vals[pos].wordName:
        let pathParts = vals[pos].wordName.split("/")
        if pathParts.len == 2:
          let vn = luaName(pathParts[0])
          let fn = luaName(pathParts[1])
          if e.isFieldSafeForConcat(vn, fn):
            e.concatSafeVars.incl(name)
      elif pos < vals.len and vals[pos].kind == vkWord and
           vals[pos].wordKind == wkWord and
           vals[pos].wordName in e.funcReturnTypes and
           e.funcReturnTypes[vals[pos].wordName] in SafeConcatTypes:
        e.concatSafeVars.incl(name)
      let expr = e.emitExprWithChain(vals, pos)
      e.ln(prefix & name & constAnnotation & " = " & expr)
      continue

    # --- Dispatch table lookup for statement-level natives ---
    if val.kind == vkWord and val.wordKind == wkWord:
      let name = val.wordName
      let stmtUserAssigned = name in e.bindings and
        not e.bindings[name].isFunction and not e.bindings[name].isUnknown
      if name in stmtHandlers and not stmtUserAssigned:
        pos += 1
        stmtHandlers[name](e, vals, pos)
        continue
      elif name in exprHandlers and not stmtUserAssigned:
        pos += 1
        var expr = exprHandlers[name](e, vals, pos)
        # Process -> method chains (same as emitExprWithChain)
        while pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordName == "->":
          pos += 1  # skip ->
          if pos >= vals.len or vals[pos].kind != vkWord: break
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
            args.add(e.emitExpr(vals, pos))
          expr = expr & ":" & methodName & "(" & args.join(", ") & ")"
        if expr.len > 0 and expr != "nil":
          if expr.startsWith("("):
            e.ln(";" & expr)
          else:
            e.ln(expr)
        continue

    # --- Control flow as statements ---
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "if":
      pos += 1
      # Check for has? with scalar — hoist to temp var instead of IIFE
      var cond: string
      if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
         vals[pos].wordName == "has?":
        let savedPos = pos
        pos += 1
        # Peek: is the needle (2nd arg) a scalar?
        var peekPos = pos
        if peekPos < vals.len: peekPos += 1  # skip block arg
        let isScalar = peekPos < vals.len and
          vals[peekPos].kind in {vkString, vkInteger, vkFloat}
        if isScalar:
          let blk = e.emitExpr(vals, pos)
          let needle = e.emitExpr(vals, pos)
          e.ln("local _has_r = false")
          e.ln("for _, x in ipairs(" & blk & ") do if x == " & needle & " then _has_r = true; break end end")
          cond = "_has_r"
        else:
          pos = savedPos
          cond = e.emitExpr(vals, pos)
      else:
        cond = e.emitExpr(vals, pos)
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

const PreludeEquals = """local function _equals(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  if #a ~= #b then return false end
  for i = 1, #a do if not _equals(a[i], b[i]) then return false end end
  return true
end
"""

const PreludeHas = """local function _has(t, v)
  for _, x in ipairs(t) do if _equals(x, v) then return true end end
  return false
end
"""

const PreludeReplace = """local function _replace(s, old, new)
  local i, j = s:find(old, 1, true)
  if not i then return s end
  local r = {}
  local p = 1
  while i do
    r[#r+1] = s:sub(p, i - 1)
    r[#r+1] = new
    p = j + 1
    i, j = s:find(old, p, true)
  end
  r[#r+1] = s:sub(p)
  return table.concat(r)
end
"""

const PreludeSelect = """local function _select(t, key)
  if type(t) == "table" and t[key] ~= nil then return t[key] end
  if type(t) == "table" then
    for i = 1, #t - 1 do if _equals(t[i], key) then return t[i + 1] end end
  end
  return nil
end
"""

const PreludeCopy = """local function _copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
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

const PreludeSplit = """local function _split(s, d)
  local r = {}
  if d == "" then
    for i = 1, #s do r[#r+1] = s:sub(i, i) end
    return r
  end
  local p = 1
  while true do
    local i, j = s:find(d, p, true)
    if not i then r[#r+1] = s:sub(p); break end
    r[#r+1] = s:sub(p, i - 1)
    p = j + 1
  end
  return r
end
"""

const PreludeInsert = """local function _insert(x, v, i)
  if type(x) == "string" then
    return x:sub(1, i - 1) .. v .. x:sub(i)
  end
  table.insert(x, i, v)
  return x
end
"""

const PreludeRemove = """local function _remove(x, i)
  if type(x) == "string" then
    return x:sub(1, i - 1) .. x:sub(i + 1)
  end
  table.remove(x, i)
  return x
end
"""

const PreludeSort = """local function _sort(x)
  if type(x) == "string" then
    local t = {}
    for i = 1, #x do t[i] = x:sub(i, i) end
    table.sort(t)
    return table.concat(t)
  end
  table.sort(x)
  return x
end
"""

const PreludeSubset = """local function _subset(x, s, n)
  if type(x) == "string" then
    return string.sub(x, s, s + n - 1)
  end
  local r = {}
  local stop = math.min(s + n - 1, #x)
  for i = s, stop do r[#r+1] = x[i] end
  return r
end
"""

const PreludeMake = """local function _make(proto, overrides, typeName)
  local inst = {}
  for k, v in pairs(proto) do inst[k] = v end
  if overrides then for k, v in pairs(overrides) do inst[k] = v end end
  if typeName then inst._type = typeName end
  return inst
end
"""

proc buildPrelude(e: LuaEmitter): string =
  if e.usedHelpers.len == 0: return ""
  result = "-- Kintsugi runtime support\n"
  result &= "math.randomseed(os.time())\n"
  result &= PreludeUnpack
  if "_NONE" in e.usedHelpers or "_is_none" in e.usedHelpers:
    result &= PreludeNone
  if "_deep_copy" in e.usedHelpers:
    result &= PreludeDeepCopy
  if "_capture" in e.usedHelpers:
    result &= PreludeCapture
  if "_equals" in e.usedHelpers:
    result &= PreludeEquals
  if "_has" in e.usedHelpers:
    result &= PreludeHas
  if "_replace" in e.usedHelpers:
    result &= PreludeReplace
  if "_select" in e.usedHelpers:
    result &= PreludeSelect
  if "_copy" in e.usedHelpers:
    result &= PreludeCopy
  if "_append" in e.usedHelpers:
    result &= PreludeAppend
  if "_split" in e.usedHelpers:
    result &= PreludeSplit
  if "_subset" in e.usedHelpers:
    result &= PreludeSubset
  if "_sort" in e.usedHelpers:
    result &= PreludeSort
  if "_insert" in e.usedHelpers:
    result &= PreludeInsert
  if "_remove" in e.usedHelpers:
    result &= PreludeRemove
  if "_make" in e.usedHelpers:
    result &= PreludeMake

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
        e.bindings[name] = bindingFunc(arity)
      else:
        e.bindings[name] = bindingFunc(0)
    of "const":
      e.nameMap[name] = luaPath
      e.bindings[name] = bindingVal()
      e.bindingKinds[name] = bkConst
    of "alias":
      # Alias emits a local declaration; no nameMap entry needed since
      # the local variable name matches the Kintsugi name via luaName.
      e.bindingKinds[name] = bkAlias
    of "assign":
      e.nameMap[name] = luaPath
      e.bindings[name] = bindingFunc(1)
      e.bindingKinds[name] = bkAssign
    of "override":
      e.nameMap[name] = luaPath
      e.bindingKinds[name] = bkOverride
    of "method":
      e.nameMap[name] = luaPath
      e.bindingKinds[name] = bkMethod
      if pos < blk.len and blk[pos].kind == vkInteger:
        let arity = int(blk[pos].intVal)
        pos += 1
        e.bindings[name] = bindingFunc(arity)
      else:
        e.bindings[name] = bindingFunc(0)
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
          let spec = parseFuncSpec(vals[i + 2].blockVals)
          var refInfos: seq[RefinementInfo] = @[]
          for r in spec.refinements:
            refInfos.add(RefinementInfo(name: r.name, paramCount: r.params.len))
          # Determine return arity: if body's last expression is `function [spec] [body]`,
          # this function returns a callable with that spec's arity.
          var retArity = -1
          if i + 3 < vals.len and vals[i + 3].kind == vkBlock:
            let body = vals[i + 3].blockVals
            if body.len >= 3 and
               body[^3].kind == vkWord and body[^3].wordKind == wkWord and
               body[^3].wordName == "function" and
               body[^2].kind == vkBlock and body[^1].kind == vkBlock:
              let innerSpec = parseFuncSpec(body[^2].blockVals)
              retArity = innerSpec.params.len
          e.bindings[name] = bindingFunc(spec.params.len, refInfos, retArity)
          # Track return type for concat-safe inference in rejoin
          if spec.returnType.len > 0:
            e.funcReturnTypes[name] = spec.returnType
          # Recurse into function body
          if i + 3 < vals.len and vals[i + 3].kind == vkBlock:
            e.prescanBlock(vals[i + 3].blockVals)
          i += 4
          continue
      # name: object [...] - register custom type and extract field specs
      elif i + 1 < vals.len and vals[i + 1].kind == vkWord and
           vals[i + 1].wordKind == wkWord and vals[i + 1].wordName == "object":
        let typeName = name.toLower.replace("-", "_")
        let kebabName = name.toLower
        e.customTypes.incl(kebabName)
        e.bindings[name] = bindingVal()  # object is a value, not a function
        # Extract field specs for inline make
        if i + 2 < vals.len and vals[i + 2].kind == vkBlock:
          let specBlock = vals[i + 2].blockVals
          var fields: seq[tuple[name: string, default: string, fieldType: string]] = @[]
          var si = 0
          while si < specBlock.len:
            let sv = specBlock[si]
            if sv.kind == vkWord and sv.wordKind == wkWord:
              # bulk: fields [required [...] optional [...]]
              if sv.wordName == "fields" and
                 si + 1 < specBlock.len and specBlock[si + 1].kind == vkBlock:
                let fieldsBlock = specBlock[si + 1].blockVals
                var fi = 0
                while fi < fieldsBlock.len:
                  if fieldsBlock[fi].kind == vkWord and fieldsBlock[fi].wordKind == wkWord:
                    let section = fieldsBlock[fi].wordName
                    fi += 1
                    if fi < fieldsBlock.len and fieldsBlock[fi].kind == vkBlock:
                      let sectionBlock = fieldsBlock[fi].blockVals
                      fi += 1
                      var bi = 0
                      while bi < sectionBlock.len:
                        if sectionBlock[bi].kind == vkWord and sectionBlock[bi].wordKind == wkWord:
                          let fieldName = luaName(sectionBlock[bi].wordName)
                          bi += 1
                          # Extract type from type block [type!]
                          var fType = ""
                          if bi < sectionBlock.len and sectionBlock[bi].kind == vkBlock:
                            let typeBlock = sectionBlock[bi].blockVals
                            if typeBlock.len >= 1 and typeBlock[0].kind == vkType:
                              fType = typeBlock[0].typeName
                            bi += 1  # skip type block
                          let isNextField = bi < sectionBlock.len and
                            sectionBlock[bi].kind == vkWord and sectionBlock[bi].wordKind == wkWord and
                            bi + 1 < sectionBlock.len and sectionBlock[bi + 1].kind == vkBlock
                          if section == "optional" and bi < sectionBlock.len and not isNextField:
                            var dpos = bi
                            let defaultVal = e.emitExpr(sectionBlock, dpos)
                            bi = dpos
                            fields.add((name: fieldName, default: defaultVal, fieldType: fType))
                          else:
                            fields.add((name: fieldName, default: "nil", fieldType: fType))
                        else:
                          bi += 1
                    else:
                      fi += 1
                  else:
                    fi += 1
                si += 2
                continue
              # field/optional or field/required
              if sv.wordName in ["field/optional", "field/required"] and
                 si + 1 < specBlock.len and specBlock[si + 1].kind == vkBlock:
                let fieldBlock = specBlock[si + 1].blockVals
                if fieldBlock.len >= 1 and fieldBlock[0].kind == vkWord:
                  let fieldName = luaName(fieldBlock[0].wordName)
                  # Extract type: field/required [name [type!]] or field/optional [name [type!] default]
                  var fType = ""
                  if fieldBlock.len >= 2 and fieldBlock[1].kind == vkBlock:
                    let typeBlock = fieldBlock[1].blockVals
                    if typeBlock.len >= 1 and typeBlock[0].kind == vkType:
                      fType = typeBlock[0].typeName
                  if sv.wordName == "field/optional" and fieldBlock.len >= 3:
                    var fpos = 2
                    let defaultVal = e.emitExpr(fieldBlock, fpos)
                    fields.add((name: fieldName, default: defaultVal, fieldType: fType))
                  else:
                    fields.add((name: fieldName, default: "nil", fieldType: fType))
                si += 2
                continue
            # set-word: method or computed field
            if specBlock[si].kind == vkWord and specBlock[si].wordKind == wkSetWord:
              let fieldName = luaName(specBlock[si].wordName)
              si += 1
              var fpos = si
              let value = e.emitExpr(specBlock, fpos)
              si = fpos
              fields.add((name: fieldName, default: value, fieldType: ""))
              continue
            si += 1
          e.objectFields[kebabName] = fields
          i += 3
        else:
          i += 2
        continue
      # name: require %path — prescan the dependency's exports
      elif i + 1 < vals.len and vals[i + 1].kind == vkWord and
           vals[i + 1].wordKind == wkWord and vals[i + 1].wordName == "import":
        if i + 2 < vals.len and vals[i + 2].kind in {vkFile, vkString}:
          when defined(js):
            # On JS: no FS — register as opaque value; main emit raises later.
            e.bindings[name] = bindingVal()
          else:
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
              e.bindings[name] = bindingVal()
              # Register name/export as the correct binding type
              for exp in exportNames:
                let pathName = name & "/" & exp
                if exp in depEmitter.bindings:
                  e.bindings[pathName] = depEmitter.bindings[exp]
          i += 3
          continue
      # name: make TypeName [...] — track variable type
      elif i + 1 < vals.len and vals[i + 1].kind == vkWord and
           vals[i + 1].wordKind == wkWord and vals[i + 1].wordName == "make":
        if i + 2 < vals.len and vals[i + 2].kind == vkWord and
           vals[i + 2].wordKind == wkWord:
          let typeName = vals[i + 2].wordName.toLower.replace("_", "-")
          e.varTypes[name] = typeName
        e.bindings[name] = bindingVal()
      else:
        # name: <non-function> — it's a value (overrides native if same name)
        e.bindings[name] = bindingVal()
    i += 1

proc inferBindings(e: var LuaEmitter, vals: seq[KtgValue]) =
  ## Inference pass: propagate return-type information.
  ## If `name: known-func args` and known-func returns a function,
  ## mark `name` as callable with the returned function's arity.
  var i = 0
  while i < vals.len:
    if vals[i].kind == vkWord and vals[i].wordKind == wkSetWord:
      let name = vals[i].wordName
      # Check RHS: is it a call to a function with known return arity?
      if i + 1 < vals.len and vals[i + 1].kind == vkWord and
         vals[i + 1].wordKind == wkWord:
        let calledName = vals[i + 1].wordName
        let info = e.getBinding(calledName)
        if info.isFunction and info.returnArity >= 0:
          e.bindings[name] = bindingFunc(info.returnArity)
      # Also check: name: does [...] — zero-arg function returning its body
      if i + 1 < vals.len and vals[i + 1].kind == vkWord and
         vals[i + 1].wordKind == wkWord and vals[i + 1].wordName == "does":
        if i + 2 < vals.len and vals[i + 2].kind == vkBlock:
          let body = vals[i + 2].blockVals
          if body.len >= 3 and
             body[^3].kind == vkWord and body[^3].wordKind == wkWord and
             body[^3].wordName == "function" and
             body[^2].kind == vkBlock and body[^1].kind == vkBlock:
            let innerSpec = parseFuncSpec(body[^2].blockVals)
            e.bindings[name] = bindingFunc(0, retArity = innerSpec.params.len)
      # Recurse into function bodies
      if i + 1 < vals.len and vals[i + 1].kind == vkWord and
         vals[i + 1].wordKind == wkWord and vals[i + 1].wordName == "function":
        if i + 3 < vals.len and vals[i + 3].kind == vkBlock:
          e.inferBindings(vals[i + 3].blockVals)
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

proc stripKtgHeader(source: string): string =
  ## Strip a leading `Kintsugi [...]` header if present, returning the
  ## body. Used both at compile time (for embedding stdlib sources) and
  ## at runtime (inside applyUsingHeader).
  let trimmed = source.strip
  if not trimmed.startsWith("Kintsugi"):
    return source
  var depth = 0
  var inHeader = false
  for i in 0 ..< source.len:
    if source[i] == '[' and not inHeader:
      inHeader = true
      depth = 1
    elif source[i] == '[' and inHeader:
      depth += 1
    elif source[i] == ']' and inHeader:
      depth -= 1
      if depth == 0:
        return source[i+1 .. ^1]
  source

const
  stdlibMathSrc = stripKtgHeader(staticRead("../../lib/math.ktg"))
  stdlibCollectionsSrc = stripKtgHeader(staticRead("../../lib/collections.ktg"))

proc extractUsingModules(source: string): seq[string] =
  ## Scan the optional `Kintsugi [using [names]]` header for module names.
  let trimmed = source.strip
  if not trimmed.startsWith("Kintsugi"):
    return @[]
  let ast = parseSource(source)
  if ast.len < 2 or ast[0].kind != vkWord or ast[0].wordName != "Kintsugi":
    return @[]
  if ast[1].kind != vkBlock:
    return @[]
  let header = ast[1].blockVals
  var i = 0
  while i < header.len:
    if header[i].kind == vkWord and
       header[i].wordKind in {wkWord, wkSetWord} and
       header[i].wordName == "using":
      i += 1
      if i < header.len and header[i].kind == vkBlock:
        for n in header[i].blockVals:
          if n.kind == vkWord:
            result.add(n.wordName)
        return
    i += 1

proc applyUsingHeader*(source: string): string =
  ## If the source has a `Kintsugi [using [math collections ...]]`
  ## header, strip the user's header and return a new source string
  ## with the requested stdlib module bodies prepended. Unknown module
  ## names are silently skipped. Sources without a header (or without
  ## `using`) are returned unchanged.
  let names = extractUsingModules(source)
  if names.len == 0:
    return source
  let userBody = stripKtgHeader(source)
  var combined = ""
  for name in names:
    case name
    of "math":        combined &= stdlibMathSrc & "\n"
    of "collections": combined &= stdlibCollectionsSrc & "\n"
    else:             discard  # unknown module — silently skip
  combined & userBody

proc collectModuleNames(vals: seq[KtgValue]): HashSet[string] =
  ## Walk the top-level values linearly and pick up every set-word.
  ## Does NOT recurse into blocks, so set-words inside function bodies,
  ## object specs, `if` bodies, etc. are not included — only names that
  ## are defined at module scope end up in the set.
  result = initHashSet[string]()
  for v in vals:
    if v.kind == vkWord and v.wordKind == wkSetWord and not v.wordName.contains('/'):
      result.incl(luaName(v.wordName))

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
    compiling: compiling,
    moduleNames: collectModuleNames(ast)
  )
  e.prescanBlock(ast)
  e.inferBindings(ast)
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

proc scanTypeChecks(e: var LuaEmitter, vals: seq[KtgValue]) =
  ## Scan AST for is? usage with custom type names.
  ## Only types referenced by is? need _type tags in make output.
  for i in 0 ..< vals.len:
    if vals[i].kind == vkBlock:
      e.scanTypeChecks(vals[i].blockVals)
    elif vals[i].kind == vkWord and vals[i].wordKind == wkWord and
         vals[i].wordName == "is?":
      # Next value is a type! — strip trailing ! and normalize to kebab-case
      if i + 1 < vals.len and vals[i + 1].kind == vkType:
        var raw = vals[i + 1].typeName.toLower
        if raw.endsWith("!"):
          raw = raw[0 ..< raw.len - 1]
        let kebab = raw.replace("_", "-")
        e.usedTypeChecks.incl(kebab)

proc emitLua*(ast: seq[KtgValue], sourceDir: string = ""): string =
  ## Walk the AST and produce Lua source code.
  var e = LuaEmitter(
    indent: 0,
    output: "",
    bindings: initNativeBindings(),
    nameMap: initTable[string, string](),
    bindingKinds: initTable[string, BindingKind](),
    sourceDir: sourceDir,
    moduleNames: collectModuleNames(ast)
  )
  e.prescanBlock(ast)
  e.inferBindings(ast)
  e.scanTypeChecks(ast)
  e.emitBlock(ast)
  e.buildPrelude() & e.output
