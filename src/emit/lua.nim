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
##   - `@preprocess` runs at compile time (not in this file).
##   - `freeze`/`frozen?` are no-ops in compiled output.

import std/[strutils, tables, sequtils, sets]
when not defined(js):
  import std/os
import ../core/[types, natives_shared, lifecycle]
import ../parse/parser
import ../eval/[stdlib_registry, evaluator]
import ./prelude_consts
import ./globals
import ./helpers

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
    paramTypes*: seq[string]  ## typeName per positional param ("" if untyped)
    paramNames*: seq[string]  ## param names, paired with paramTypes

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
    ## Object field specs: typeName -> seq[(fieldName, defaultExpr, fieldType, arity)].
    ## Populated during prescan so make can inline fields, rejoin can check
    ## types, and `->` can determine method arity. `arity` is -1 for plain
    ## values, 0+ for function-typed methods.
    objectFields: Table[string, seq[tuple[name: string, default: string,
                                          fieldType: string, arity: int]]]
    ## Custom types that have is? checks — only these need _type tags.
    usedTypeChecks: HashSet[string]
    ## Per-scope variable type / sequence / concat-safety tracking.
    ## Keyed by Kintsugi name (kebab-case); populated when a binding's
    ## type is known from `make Type [...]`, a typed param, or an RHS
    ## analysis in the set-word path. Saved and restored as a unit when
    ## entering/leaving function bodies.
    varTable: Table[string, VarInfo]
    ## Function return types: funcName -> type string ("integer!",
    ## "string!", etc.). Module-scope registry; not saved per-fn.
    funcReturnTypes: Table[string, string]
    ## Variable names bound to a context literal; iterate with pairs() not ipairs().
    contextVars: HashSet[string]
    ## Set when the program uses any random-returning native or math.randomseed.
    usedRandom: bool
    ## Set when the program uses variadic unpack (set destructure rest, apply, etc.)
    usedVariadicUnpack: bool
    ## Set if the program contains any `none?` usage; when false, `none`
    ## emits as `nil` and the _NONE sentinel helper is skipped.
    programUsesNoneCheck: bool
    ## @type-declared custom type rules. Keyed by base name (no trailing !).
    customTypeRules: Table[string, CustomTypeRule]
    ## User fns declared as `name: @type/guard [params] [body]`. Eligible
    ## for use inside @type/guard bodies and @type where-guard bodies.
    guardFuncs: HashSet[string]
    ## Stored guard fn bodies + param names, validated after all of
    ## prescan to support mutually-recursive guards.
    guardFuncBodies: Table[string,
      tuple[body: seq[KtgValue], paramNames: HashSet[string], line: int]]
    ## Stdlib modules referenced by `import 'name` or
    ## `import/using 'name [...]`. Whole-module imports use sentinel
    ## "*" in the symbol set; selective imports list explicit names.
    ## buildPrelude calls expandStdlibIntoPrelude to materialize them.
    usedStdlibSymbols: Table[string, HashSet[string]]
    ## Optional evaluator for compile-time guard checks on literal
    ## arguments at call sites. When nil, compile-time checks are
    ## skipped and guards fall through to the runtime prologue.
    eval*: Evaluator
    ## Compile target ("", "love2d", "playdate"). Drives target-specific
    ## global allowlists in the strict-globals diagnostic.
    target: string
    ## Dependency .lua files produced by `import %path`. The emitter
    ## never writes these itself — it accumulates (absolutePath, luaSource)
    ## pairs here, and the caller (CLI) flushes them after emission. Keeps
    ## emit/lua.nim filesystem-free except for reading dep sources during
    ## compilation. Phase 3a goal.
    pendingDepWrites*: seq[tuple[path: string, lua: string]]

  CustomTypeKind* = enum
    ctUnion       ## @type [t! | t!]
    ctWhere       ## @type/where [t!] [guard]
    ctEnum        ## @type/enum ['a | 'b]

  CustomTypeRule* = object
    case kind*: CustomTypeKind
    of ctUnion:
      unionTypes*: seq[string]      ## base type names (e.g. "integer!", "string!")
    of ctWhere:
      whereTypes*: seq[string]      ## base type names ANDed with guard
      guardBody*: seq[KtgValue]     ## body block using `it`
    of ctEnum:
      enumMembers*: seq[string]     ## lit-word names (case-sensitive)

  SeqType* = enum
    stUnknown
    stString
    stBlock

  VarInfo* = object
    ## Per-scope variable tracking used by the emitter to specialize
    ## emission for typed values. Consolidates what was three separate
    ## tables (varTypes, varSeqTypes, concatSafeVars) into one struct
    ## keyed by Kintsugi variable name.
    ktgType*: string          ## kebab-cased type (e.g. "enemy"); "" if unknown
    seqType*: SeqType         ## stUnknown / stString / stBlock
    concatSafe*: bool         ## safe to use as operand of Lua `..`

  EmitError* = ref object of CatchableError

  ## An expression emitter: given vals and pos, consume arguments and
  ## return a typed Lua expression. Callers project `.text` where a raw
  ## Lua fragment is needed for statement composition.
  ExprHandler = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr

  ## A statement emitter: given vals and pos, consume arguments and emit Lua statements via e.ln().
  StmtHandler = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int)

var exprHandlers = initTable[string, ExprHandler]()
var stmtHandlers = initTable[string, StmtHandler]()

## Register an expression handler.
proc registerExpr(name: string, h: ExprHandler) =
  exprHandlers[name] = h

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

const BuiltinTypePredicates = ["integer?", "float?", "number?", "string?",
                               "logic?", "none?", "block?"]

## Natives that exist in the interpreter but cannot be compiled to Lua.
## Calling any of these from compiled code is a hard compile error instead of
## silently emitting a call to a nonexistent Lua function.
##
## The IO + exit natives have direct Lua analogues (`io.read`, `io.open`,
## `os.exit`), but those analogues are not portable across our three targets:
## LOVE2D sandboxes filesystem access through `love.filesystem`, Playdate
## exposes `playdate.file`, and standalone Lua uses `io`/`os`. Rather than
## pick one and silently break the others, the emitter refuses and points
## users at target-native bindings via the `bindings [...]` escape hatch.
## `charset` exists only for the @parse dialect, which is interpreter-only.
##
## The `compilable: false` flag on the corresponding KtgNative registrations
## in `src/eval/natives*.nim` mirrors this list; both must agree.
const InterpreterOnlyNatives = [
  "read", "write", "save", "dir?", "file?",
  "exit", "charset",
]

proc interpreterOnlyHint(name: string): string =
  case name
  of "read", "write", "save":
    "filesystem IO is not available in the compiled target. Precompute " &
    "the data via @preprocess and emit it into the source, or move this " &
    "call into an interpreter-only script."
  of "dir?", "file?":
    "filesystem queries are not available in the compiled target."
  of "exit":
    "exit is not portable across targets. Use target-native calls (for " &
    "example love/event/quit on LOVE2D) from a raw binding instead."
  of "charset":
    "charset only exists for the @parse dialect, which is interpreter-only. " &
    "Restructure to avoid it in compiled code."
  else:
    "this native is not available in compiled output."

proc pad(e: LuaEmitter): string =
  repeat("  ", e.indent)

proc useHelper(e: var LuaEmitter, name: string) =
  ## Mark a prelude helper as used. Dependencies are automatic:
  ## _is_none and _NONE depend on each other, unpack is always included.
  e.usedHelpers.incl(name)
  if name == "_is_none": e.usedHelpers.incl("_NONE")
  if name == "_NONE": e.usedHelpers.incl("_is_none")

# --- VarInfo accessors ------------------------------------------------------
# Thin wrappers over e.varTable to keep call sites readable. Reads default
# to a zero-valued VarInfo; writes upsert.

proc varInfo(e: LuaEmitter, name: string): VarInfo =
  if name in e.varTable: e.varTable[name]
  else: VarInfo()

proc varType(e: LuaEmitter, name: string): string = e.varInfo(name).ktgType
proc varSeqType(e: LuaEmitter, name: string): SeqType = e.varInfo(name).seqType
proc varConcatSafe(e: LuaEmitter, name: string): bool = e.varInfo(name).concatSafe

proc hasVarType(e: LuaEmitter, name: string): bool =
  name in e.varTable and e.varTable[name].ktgType.len > 0
proc hasVarSeqType(e: LuaEmitter, name: string): bool =
  name in e.varTable and e.varTable[name].seqType != stUnknown

proc setVarType(e: var LuaEmitter, name, ktgType: string) =
  var info = e.varInfo(name)
  info.ktgType = ktgType
  e.varTable[name] = info

proc setVarSeqType(e: var LuaEmitter, name: string, st: SeqType) =
  var info = e.varInfo(name)
  info.seqType = st
  e.varTable[name] = info

proc markConcatSafe(e: var LuaEmitter, name: string) =
  var info = e.varInfo(name)
  info.concatSafe = true
  e.varTable[name] = info

const SafeConcatTypes = ["integer!", "float!", "string!", "money!"]

## Return types whose Lua representation is a native scalar (number,
## string, boolean, nil) — `print`/`probe` can render these directly
## without `_prettify`. Table-like types (block!, context!, objects)
## stay wrapped because Lua's default `tostring` shows `table: 0x...`.
const ScalarReturnTypes = ["integer!", "float!", "number!", "string!",
                            "logic!", "none!"]

proc isFieldSafeForConcat(e: LuaEmitter, varName, fieldName: string): bool =
  ## Check if varName.fieldName is a type safe for Lua's .. operator.
  ## Safe types: integer!, float!, string!, money! (all auto-coerce or are strings).
  let kebabVar = varName.replace("_", "-")
  if e.hasVarType(kebabVar):
    let typeName = e.varType(kebabVar)
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

# ---------------------------------------------------------------------------
# Native arity table — what the emitter needs to know about built-in funcs
# ---------------------------------------------------------------------------
# (sanitize, luaEscape, and other pure string/AST helpers live in helpers.nim)

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

## Global allowlists (LuaReserved, LuaStdlibGlobals, Love2dGlobals,
## PlaydateGlobals) live in globals.nim; luaName and other pure helpers
## live in helpers.nim. All re-exported via import above.

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
proc emitExprTyped(e: var LuaEmitter, vals: seq[KtgValue], pos: var int,
                   primary: bool = false): LuaExpr
proc emitBody(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false)
proc emitBlock(e: var LuaEmitter, vals: seq[KtgValue], asReturn: bool = false)
proc emitMatchExpr(e: var LuaEmitter, valueExpr: string, rulesBlock: seq[KtgValue]): string
proc emitMatchHoisted(e: var LuaEmitter, varName: string, valueExpr: string,
                      rulesBlock: seq[KtgValue])
proc emitAttemptExpr(e: var LuaEmitter, blk: seq[KtgValue]): string
proc emitEitherExpr(e: var LuaEmitter, cond: string, trueBlock, falseBlock: seq[KtgValue]): string
proc emitLuaModule*(ast: seq[KtgValue], sourceDir: string = "",
                    compiling: HashSet[string] = initHashSet[string](),
                    eval: Evaluator = nil,
                    target: string = ""):
    tuple[lua: string, depWrites: seq[tuple[path: string, lua: string]]]
proc emitLuaModuleEx(ast: seq[KtgValue], sourceDir: string,
                     compiling: HashSet[string],
                     eval: Evaluator = nil,
                     target: string = ""):
    tuple[lua: string, e: LuaEmitter]
proc findExports(ast: seq[KtgValue]): seq[string]
proc emitContextBlock(e: var LuaEmitter, vals: seq[KtgValue]): string
proc emitFuncDef(e: var LuaEmitter, specBlock, bodyBlock: seq[KtgValue]): string
proc inferSeqType(e: LuaEmitter, vals: seq[KtgValue], pos: int): SeqType
proc prescanBlock(e: var LuaEmitter, vals: seq[KtgValue])

# ---------------------------------------------------------------------------
# Compile-error guards for interpreter-only features
# ---------------------------------------------------------------------------

proc isKnownName(e: LuaEmitter, name: string): bool =
  ## A name is "known" if the emitter can resolve it without emitting an
  ## undeclared Lua global. Covers: user bindings from prescan, native
  ## natives, declared locals in the current scope chain, top-level
  ## module set-words, foreign-binding paths from the bindings dialect,
  ## Kintsugi identifiers that sanitize to Lua reserved words (prefixed
  ## with _k_), the Lua stdlib allowlist, and target-specific globals.
  if name.len == 0: return true
  let sanitized = sanitize(name)
  if sanitized in LuaReserved: return true  # will emit as _k_<name>
  if name in e.bindings: return true
  if name in e.nameMap: return true
  if luaName(name) in e.locals: return true
  if luaName(name) in e.moduleNames: return true
  if name in e.guardFuncs: return true
  if name in LuaStdlibGlobals or sanitized in LuaStdlibGlobals: return true
  case e.target
  of "love2d":
    if name in Love2dGlobals or sanitized in Love2dGlobals: return true
  of "playdate":
    if name in PlaydateGlobals or sanitized in PlaydateGlobals: return true
  else: discard
  false

proc assertKnownName(e: LuaEmitter, name: string, line: int) =
  ## Strict-globals diagnostic: raise if the emitter is about to produce a
  ## bare Lua global reference to an undeclared name. This catches typos
  ## and forgotten `bindings` entries at compile time rather than letting
  ## them surface as runtime `attempt to call a nil value` errors.
  # Path heads: only check the head segment; the remaining segments are
  # field access, not independent global lookups.
  let headName = if '/' in name: name.split('/')[0] else: name
  if e.isKnownName(headName): return
  raise EmitError(
    msg: "======== COMPILE ERROR ========\n" &
         "Undeclared identifier: '" & headName & "'" &
         (if line > 0: " @ line " & $line else: "") & "\n" &
         "  hint: if this should be a Lua global or target-native, add a " &
         "`bindings [...]` entry. If it's a typo, fix the spelling. If " &
         "it's a local variable, declare it with `name: value` first."
  )

proc compileError(feature, hint: string, line: int) =
  raise EmitError(
    msg: "======== COMPILE ERROR ========\n" &
         "Interpreter-Only Feature\n" &
         "'" & feature & "' cannot be used in compiled output -- it requires runtime evaluation" &
         (if line > 0: " @ line " & $line else: "") & "\n" &
         "  hint: " & hint
  )

proc guardValidationError(fnName, offendingWord, reason: string, line: int) =
  raise EmitError(
    msg: "======== COMPILE ERROR ========\n" &
         "@type/guard body not compileable\n" &
         "@type/guard '" & fnName & "' calls '" & offendingWord & "'" &
         (if line > 0: " @ line " & $line else: "") & "\n" &
         "  reason: " & reason & "\n" &
         "  hint: mark '" & offendingWord &
         "' as @type/guard, or use a compileable alternative."
  )

## Names of every built-in native, computed once from natives_shared.
let allNativeNames {.global.} = block:
  var s = initHashSet[string]()
  for (n, _) in nativeArities:
    s.incl(n)
  for n in typePredNames:
    s.incl(n & "?")
  s

proc validateGuardBody(e: var LuaEmitter, fnName: string,
                        body: seq[KtgValue], paramNames: HashSet[string]) =
  ## Walk a @type/guard fn body's AST. Every wkWord in head position must
  ## resolve to (a) a param name, (b) a built-in compileable native, or
  ## (c) another @type/guard fn. Anything else is a compile error.
  ##
  ## "It" is allowed unconditionally - it's the standard guard binding.
  ## Path words (containing '/') are field/module access, not calls.
  for v in body:
    case v.kind
    of vkBlock:
      e.validateGuardBody(fnName, v.blockVals, paramNames)
    of vkParen:
      e.validateGuardBody(fnName, v.parenVals, paramNames)
    of vkWord:
      if v.wordKind == wkWord:
        let name = v.wordName
        if name == "it" or name in paramNames:
          continue
        if '/' in name:
          continue
        if name in allNativeNames:
          if name in InterpreterOnlyNatives:
            guardValidationError(fnName, name,
              "'" & name & "' is a built-in native marked interpreter-only.",
              v.line)
          continue
        if name in e.guardFuncs:
          continue
        guardValidationError(fnName, name,
          "'" & name & "' is neither a compileable built-in nor a " &
          "@type/guard-marked user fn.",
          v.line)
    else:
      discard

proc validateAllGuards(e: var LuaEmitter) =
  ## Run after prescan: validate every registered @type/guard fn body.
  ## Late-running so mutually-recursive guards can resolve each other.
  for fnName, info in e.guardFuncBodies:
    e.validateGuardBody(fnName, info.body, info.paramNames)

# ---------------------------------------------------------------------------
# Handler factories
# ---------------------------------------------------------------------------

## Factory for math.X(arg) patterns.
proc mathUnary(luaFn: string): ExprHandler =
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
    lxCall(luaFn & "(" & e.emitExpr(vals, pos) & ")")

## Factory for string.X(arg) patterns.
proc stringUnary(luaFn: string): ExprHandler =
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
    lxCall(luaFn & "(" & e.emitExpr(vals, pos) & ")")

## Factory for math.X(a, b) patterns.
proc mathBinary(luaFn: string): ExprHandler =
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
    let a = e.emitExpr(vals, pos)
    let b = e.emitExpr(vals, pos)
    lxCall(luaFn & "(" & a & ", " & b & ")")

# ---------------------------------------------------------------------------
# Math expression handlers
# ---------------------------------------------------------------------------

# abs — compile-time reject when arg is known money-typed. Money has no
# natural unsigned magnitude; `negate` is the right tool for sign flips.
# Catches literals and params typed `money!`; bare vars assigned from a
# money literal aren't tracked and fall through to math.abs (which errors
# loudly at runtime with "number expected, got table").
registerExpr("abs", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len:
    let v = vals[pos]
    let isMoneyArg =
      v.kind == vkMoney or
      (v.kind == vkWord and v.wordKind == wkWord and
       e.varType(v.wordName) == "money")
    if isMoneyArg:
      raise EmitError(msg:
        "abs does not apply to money! - use negate to flip sign")
  lxCall("math.abs(" & e.emitExpr(vals, pos) & ")"))
registerExpr("sqrt", mathUnary("math.sqrt"))
registerExpr("sin", mathUnary("math.sin"))
registerExpr("cos", mathUnary("math.cos"))
registerExpr("tan", mathUnary("math.tan"))
registerExpr("asin", mathUnary("math.asin"))
registerExpr("acos", mathUnary("math.acos"))
registerExpr("exp", mathUnary("math.exp"))
registerExpr("log", mathUnary("math.log"))
registerExpr("log10", mathUnary("math.log10"))
registerExpr("to-degrees", mathUnary("math.deg"))
registerExpr("to-radians", mathUnary("math.rad"))
registerExpr("floor", mathUnary("math.floor"))
registerExpr("ceil", mathUnary("math.ceil"))

# Binary math.X(a, b) natives
registerExpr("min", mathBinary("math.min"))
registerExpr("max", mathBinary("math.max"))
registerExpr("atan2", mathBinary("math.atan2"))
registerExpr("pow", mathBinary("math.pow"))

# Custom math handlers — paren-wrapped outputs are lxCall-safe (no further
# wrapping needed by composing operators).
registerExpr("negate", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExpr(vals, pos)
  lxCall("-(" & arg & ")"))

registerExpr("odd?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExpr(vals, pos)
  lxCall("(" & arg & " % 2 ~= 0)"))

registerExpr("even?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExpr(vals, pos)
  lxCall("(" & arg & " % 2 == 0)"))

registerExpr("round", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExpr(vals, pos)
  lxCall("math.floor(" & arg & " + 0.5)"))

registerExpr("pi", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxLit("math.pi"))

# `none` word — the Kintsugi sentinel. Emits `_NONE` so blocks containing
# none round-trip correctly (Lua `nil` terminates a contiguous table;
# `_NONE` is a real value that survives length/ipairs/table.concat).
registerExpr("none", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  e.useHelper("_NONE")
  lxLit("_NONE"))

# ---------------------------------------------------------------------------
# String expression handlers
# ---------------------------------------------------------------------------

registerExpr("uppercase", stringUnary("string.upper"))
registerExpr("lowercase", stringUnary("string.lower"))

registerExpr("trim", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExpr(vals, pos)
  lxCall("(" & arg & "):match(\"^%s*(.-)%s*$\")"))

registerExpr("length", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxCall("#" & e.emitExpr(vals, pos)))

registerExpr("empty?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExpr(vals, pos)
  lxCall("(#" & arg & " == 0)"))

# ---------------------------------------------------------------------------
# Type predicate expression handlers
# ---------------------------------------------------------------------------

## Factory for `type(arg) == "X"` predicates. The result is an `==` infix
## at prec 3; composition with `and`/`or` (prec 2/1) is safe without outer
## parens, and `not` wraps its own arg.
proc typePred(luaType: string): ExprHandler =
  result = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
    lxInfix("type(" & e.emitExpr(vals, pos) & ") == \"" & luaType & "\"", luaPrec("=="))

# Simple type(arg) == "X" predicates
registerExpr("string?", typePred("string"))
registerExpr("logic?", typePred("boolean"))
registerExpr("number?", typePred("number"))

# Table-backed types
registerExpr("block?", typePred("table"))
registerExpr("context?", typePred("table"))
registerExpr("object?", typePred("table"))
registerExpr("map?", typePred("table"))

# Freeze - no-op in compiled output; passthrough preserves the inner shape.
registerExpr("freeze", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxOther(e.emitExpr(vals, pos, primary = true)))
registerExpr("frozen?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  discard e.emitExpr(vals, pos, primary = true)
  lxLit("false"))

# Function types
registerExpr("function?", typePred("function"))
registerExpr("native?", typePred("function"))

# none? — direct `arg == nil` at `==` precedence.
registerExpr("none?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxInfix(e.emitExpr(vals, pos) & " == nil", luaPrec("==")))

# integer? / float? — compound `and`-joined checks at `and` precedence.
# Multiple arg references require safeArg parenthesization when the arg
# already contains `and`/`or`.
registerExpr("integer?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExprTyped(vals, pos)
  let safeArg = paren(arg, luaPrec("and"))
  lxInfix("type(" & safeArg & ") == \"number\" and math.floor(" & safeArg & ") == " & safeArg,
          luaPrec("and")))

registerExpr("float?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExprTyped(vals, pos)
  let safeArg = paren(arg, luaPrec("and"))
  lxInfix("type(" & safeArg & ") == \"number\" and math.floor(" & safeArg & ") ~= " & safeArg,
          luaPrec("and")))

# Nominal-type fallback predicates — same shape as typePred, reused.
for baseName in ["money", "pair", "tuple", "date", "time", "file", "url",
                 "email", "set", "paren", "word", "type"]:
  registerExpr(baseName & "?", typePred(baseName))

# ---------------------------------------------------------------------------
# Infix operators
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Simple native expression handlers
# ---------------------------------------------------------------------------

# --- raw: splice string contents verbatim as a Lua expression fragment ---
# The user-supplied string may be anything; tag lxOther to discourage any
# automatic wrapping by paren().
registerExpr("raw", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkString:
    let s = vals[pos].strVal
    pos += 1
    return lxOther(s)
  lxOther(""))

# --- Refinement natives ---
registerExpr("round/down", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxCall("math.floor(" & e.emitExpr(vals, pos) & ")"))

registerExpr("round/up", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxCall("math.ceil(" & e.emitExpr(vals, pos) & ")"))

registerExpr("copy/deep", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExpr(vals, pos)
  e.useHelper("_deep_copy")
  lxCall("_deep_copy(" & arg & ")"))

registerExpr("sort/by", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arr = e.emitExpr(vals, pos)
  let keyFn = e.emitExpr(vals, pos)
  lxOther("(function() local _key = " & keyFn & "; table.sort(" & arr & ", function(a, b) return _key(a) < _key(b) end); return " & arr & " end)()"))

registerExpr("sort/with", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arr = e.emitExpr(vals, pos)
  let cmpFn = e.emitExpr(vals, pos)
  lxOther("(function() table.sort(" & arr & ", " & cmpFn & "); return " & arr & " end)()"))

# --- system/platform → compile-time constant ---
registerExpr("system/platform", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxLit("\"lua\""))

# --- now → os.time() (epoch timestamp) ---
registerExpr("now", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxCall("os.time()"))

# --- function / does / context / try / try/handle ---
# function / does produce `(function(...) ... end)` IIFE-wrapped values —
# tagged lxOther (no natural precedence; always safe as a standalone term).
registerExpr("function", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos + 1 < vals.len and vals[pos].kind == vkBlock and vals[pos + 1].kind == vkBlock:
    let specBlock = vals[pos].blockVals
    let bodyBlock = vals[pos + 1].blockVals
    pos += 2
    lxOther(e.emitFuncDef(specBlock, bodyBlock))
  else:
    lxLit("nil"))

registerExpr("does", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let bodyBlock = vals[pos].blockVals
    pos += 1
    lxOther(e.emitFuncDef(@[], bodyBlock))
  else:
    lxLit("nil"))

registerExpr("context", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    lxTableCtor(e.emitContextBlock(blk))
  else:
    lxTableCtor("{}"))

registerExpr("try", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    e.indent += 1
    let bodyStr = withCapture(e):
      e.emitBody(blk, asReturn = true)
    e.indent -= 1
    lxOther("(function()\n" &
      e.pad & "  local ok, result = pcall(function()\n" &
      bodyStr &
      e.pad & "  end)\n" &
      e.pad & "  if ok then return {ok=true, value=result}\n" &
      e.pad & "  else return {ok=false, message=result} end\n" &
      e.pad & "end)()")
  else:
    lxLit("nil"))

registerExpr("try/handle", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    var handlerBody = ""
    if pos < vals.len and vals[pos].kind == vkBlock:
      let hblk = vals[pos].blockVals
      pos += 1
      let savedLocals = e.locals
      e.indent += 2
      e.locals.incl("it")
      handlerBody = withCapture(e):
        e.emitBody(hblk, asReturn = true)
      e.locals = savedLocals
    e.indent += 1
    let bodyStr = withCapture(e):
      e.emitBody(blk, asReturn = true)
    e.indent -= 1
    lxOther("(function()\n" &
      e.pad & "  local ok, it = pcall(function()\n" &
      bodyStr &
      e.pad & "  end)\n" &
      e.pad & "  if ok then return it\n" &
      e.pad & "  else\n" &
      handlerBody &
      e.pad & "  end\n" &
      e.pad & "end)()")
  else:
    lxLit("nil"))

## (primitiveTypeCheck and customTypePredicateName live in helpers.nim.)

proc emitCustomTypeCheck(e: var LuaEmitter, typeName, valExpr: string): string

proc emitAnyTypeCheckTyped(e: var LuaEmitter, typeName, valExpr: string): LuaExpr =
  ## Dispatch: primitive first, then user-declared custom type (synthesized
  ## predicate call), else fall back to the object-auto-gen _type tag.
  ## Result may be `lxInfix` composed with `and`; callers that compose with
  ## further `and`/`or` use `paren(result, luaPrec("and"))` to wrap precisely.
  let primTyped = primitiveTypeCheckTyped(typeName, valExpr)
  if primTyped.text.len > 0: return primTyped
  if typeName in e.customTypeRules:
    # Predicate is synthesized in the prelude; emit a call. Mark used.
    e.usedTypeChecks.incl(typeName)
    return lxCall(customTypePredicateName(typeName) & "(" & valExpr & ")")
  lxInfix(valExpr & " ~= nil and type(" & valExpr & ") == \"table\" and " &
          valExpr & "._type == \"" & typeName & "\"",
          luaPrec("and"))

proc emitAnyTypeCheck(e: var LuaEmitter, typeName, valExpr: string): string =
  ## Back-compat string projection.
  emitAnyTypeCheckTyped(e, typeName, valExpr).text

proc emitCustomTypeCheck(e: var LuaEmitter, typeName, valExpr: string): string =
  ## Inline predicate for a @type-declared custom type.
  let rule = e.customTypeRules[typeName]
  case rule.kind
  of ctUnion:
    if rule.unionTypes.len == 0: return "false"
    var parts: seq[string]
    for t in rule.unionTypes:
      let base = if t.endsWith("!"): t[0 ..< t.len - 1] else: t
      parts.add(e.emitAnyTypeCheck(base, valExpr))
    if parts.len == 1: parts[0]
    else: parts.join(" or ")
  of ctWhere:
    let savedIndent = e.indent
    let savedLocals = e.locals
    e.indent += 1
    e.locals.incl("it")  # guard body binds `it` as its parameter
    let guardBody = withCapture(e, e.emitBlock(rule.guardBody, asReturn = true))
    e.indent = savedIndent
    e.locals = savedLocals
    let guardCall = "(function(it)\n" & guardBody & e.pad & "end)(" & valExpr & ")"
    if rule.whereTypes.len == 0:
      return guardCall
    var parts: seq[string]
    for t in rule.whereTypes:
      let base = if t.endsWith("!"): t[0 ..< t.len - 1] else: t
      parts.add(e.emitAnyTypeCheck(base, valExpr))
    let baseCheck =
      if parts.len == 1: parts[0]
      else: "(" & parts.join(" or ") & ")"
    baseCheck & " and " & guardCall
  of ctEnum:
    if rule.enumMembers.len == 0: return "false"
    var parts: seq[string]
    for m in rule.enumMembers:
      parts.add(valExpr & " == \"" & m & "\"")
    parts.join(" or ")

proc emitCustomTypePredicateDecl(e: var LuaEmitter, typeName: string): string =
  ## Build a Lua function declaration for the synthesized predicate of a
  ## @type. The body uses `it` as the value parameter so where-guard bodies
  ## (which already bind `it`) compile transparently.
  let rule = e.customTypeRules[typeName]
  let fnName = customTypePredicateName(typeName)

  proc baseCheckExpr(e: var LuaEmitter, t: string): string =
    let base = if t.endsWith("!"): t[0 ..< t.len - 1] else: t
    let primTyped = primitiveTypeCheckTyped(base, "it")
    if primTyped.text.len > 0:
      # Wrap at `and` precedence so composed `type() == "x" and ...` checks
      # (integer/float) get parens; simple `type() == "x"` checks (prec 3 >
      # "and" prec 2) are left bare.
      return paren(primTyped, luaPrec("and"))
    if base in e.customTypeRules:
      return customTypePredicateName(base) & "(it)"
    # Unknown / object-nominal type — fall back to _type-tag check.
    "(type(it) == \"table\" and it._type == \"" & base & "\")"

  case rule.kind
  of ctUnion:
    var parts: seq[string]
    for t in rule.unionTypes:
      parts.add(e.baseCheckExpr(t))
    let body = if parts.len == 0: "false" else: parts.join(" or ")
    "function " & fnName & "(it)\n  return " & body & "\nend"

  of ctEnum:
    var parts: seq[string]
    for m in rule.enumMembers:
      parts.add("it == \"" & m & "\"")
    let body = if parts.len == 0: "false" else: parts.join(" or ")
    "function " & fnName & "(it)\n  return " & body & "\nend"

  of ctWhere:
    var baseParts: seq[string]
    for t in rule.whereTypes:
      baseParts.add(e.baseCheckExpr(t))
    let baseCheck =
      if baseParts.len == 0: "true"
      elif baseParts.len == 1: baseParts[0]
      else: "(" & baseParts.join(" or ") & ")"

    let savedIndent = e.indent
    let savedLocals = e.locals
    e.indent = 1
    e.locals.incl("it")  # predicate body binds `it` as its parameter
    let guardBody = withCapture(e, e.emitBlock(rule.guardBody, asReturn = true))
    e.indent = savedIndent
    e.locals = savedLocals

    "function " & fnName & "(it)\n" &
      "  if not " & baseCheck & " then return false end\n" &
      guardBody.strip(chars = {'\n'}) & "\nend"

# --- is? — unified type checking ---
registerExpr("is?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let typeExpr = e.emitExpr(vals, pos, primary = true)
  let valExpr = e.emitExpr(vals, pos, primary = true)
  var typeName = typeExpr.strip(chars = {'"'})
  if typeName.endsWith("!"):
    typeName = typeName[0..^2]
  # Tag as lxBool so downstream print/probe can skip `_prettify` — the
  # result is always a scalar boolean. `paren(_, luaPrec("and"))` defensively
  # parenthesizes composed `and`/`or` bodies (primitive + where-guard) for
  # safe composition at higher precedences.
  let innerTyped = e.emitAnyTypeCheckTyped(typeName, valExpr)
  lxBool(paren(innerTyped, luaPrec("and"))))

proc prettifyForPrint(e: var LuaEmitter, expr: LuaExpr): string =
  ## Lua's print/tostring on a table returns "table: 0x...". Wrap only
  ## expressions that could be a table. Lua prints booleans/numbers/strings/
  ## nil natively, so any expression kind we can prove is scalar skips the
  ## `_prettify` wrap — which also lets the helper itself stay out of the
  ## prelude when nothing else needs it.
  ##   - lxLiteral: bare identifier or literal; trust source shape.
  ##   - lxBool: guaranteed boolean (e.g. `is?`).
  ##   - lxInfix at `==`/comparison/arith/`..` precedence: Lua operator
  ##     semantics guarantee scalar. `and`/`or` (prec 1-2) are excluded —
  ##     they short-circuit-return an operand that may be a table.
  if expr.kind == lxLiteral: return expr.text
  if expr.kind == lxBool: return expr.text
  if expr.kind == lxScalar: return expr.text
  if expr.kind == lxInfix and expr.prec >= luaPrec("=="): return expr.text
  e.useHelper("_prettify")
  "_prettify(" & expr.text & ")"

# --- print ---
registerExpr("print", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExprTyped(vals, pos)
  lxCall("print(" & prettifyForPrint(e,arg) & ")"))

# --- probe (returns value) ---
registerExpr("probe", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExpr(vals, pos)
  # `_v` is a bare identifier — classify as literal for the print heuristic.
  let printed = prettifyForPrint(e,lxLit("_v"))
  lxOther("(function() local _v = " & arg & "; print(" & printed & "); return _v end)()"))

# --- not --- unary boolean; its arg is parenthesized so the result composes
# safely at any precedence. Tagged lxCall so `paren` leaves it alone.
registerExpr("not", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExpr(vals, pos)
  if arg.startsWith("(") or arg.startsWith("not "): lxCall("not " & arg)
  else: lxCall("not (" & arg & ")"))

# --- return --- `return` + expression; always a statement-ish expression.
registerExpr("return", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxOther("return " & e.emitExpr(vals, pos)))

# --- join --- two-arg string concat, prec 4 (..)
registerExpr("join", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let a = e.emitExpr(vals, pos)
  let b = e.emitExpr(vals, pos)
  lxInfix("tostring(" & a & ") .. tostring(" & b & ")", luaPrec("..")))

# --- Series operations ---
registerExpr("first", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let seqType = e.inferSeqType(vals, pos)
  # paren at minPrec=0: wraps only lxTableCtor (needs outer parens to index
  # a bare `{...}` literal); lxInfix is never wrapped since its prec is > 0.
  let arg = paren(e.emitExprTyped(vals, pos), 0)
  case seqType
  of stString: lxCall(arg & ":sub(1, 1)")
  else: lxCall(arg & "[1]"))

registerExpr("second", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let seqType = e.inferSeqType(vals, pos)
  let arg = paren(e.emitExprTyped(vals, pos), 0)
  case seqType
  of stString: lxCall(arg & ":sub(2, 2)")
  else: lxCall(arg & "[2]"))

registerExpr("last", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let seqType = e.inferSeqType(vals, pos)
  let arg = e.emitExpr(vals, pos)
  # Simple identifier: emit arg[#arg]. Complex expression: use temp to avoid double eval.
  let isSimple = arg.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '.'})
  case seqType
  of stString:
    if isSimple: lxCall(arg & ":sub(#" & arg & ", #" & arg & ")")
    else: lxOther("(function() local _t = " & arg & "; return _t:sub(#_t, #_t) end)()")
  else:
    if isSimple: lxCall(arg & "[#" & arg & "]")
    else: lxOther("(function() local _t = " & arg & "; return _t[#_t] end)()"))

registerExpr("pick", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let seqType = e.inferSeqType(vals, pos)
  let blkTyped = e.emitExprTyped(vals, pos)
  let idx = e.emitExpr(vals, pos)
  let wrapped = paren(blkTyped, 0)
  case seqType
  of stString: lxCall(wrapped & ":sub(" & idx & ", " & idx & ")")
  else: lxCall(wrapped & "[" & idx & "]"))

registerExpr("append", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let blk = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  e.useHelper("_append")
  lxCall("_append(" & blk & ", " & val_expr & ")"))

registerExpr("append/only", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let blk = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  lxOther("(function() table.insert(" & blk & ", " & val_expr & "); return " & blk & " end)()"))

registerExpr("copy", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let arg = e.emitExpr(vals, pos)
  e.useHelper("_copy")
  lxCall("_copy(" & arg & ")"))

registerExpr("insert", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let seqType = e.inferSeqType(vals, pos)
  let blk = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  let idx_expr = e.emitExpr(vals, pos)
  case seqType
  of stString:
    lxInfix(blk & ":sub(1, " & idx_expr & " - 1) .. " & val_expr & " .. " & blk & ":sub(" & idx_expr & ")", luaPrec(".."))
  of stBlock:
    lxOther("(function() table.insert(" & blk & ", " & idx_expr & ", " & val_expr & "); return " & blk & " end)()")
  of stUnknown:
    e.useHelper("_insert")
    lxCall("_insert(" & blk & ", " & val_expr & ", " & idx_expr & ")"))

registerExpr("remove", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let seqType = e.inferSeqType(vals, pos)
  let blk = e.emitExpr(vals, pos)
  let idx_expr = e.emitExpr(vals, pos)
  case seqType
  of stString:
    lxInfix(blk & ":sub(1, " & idx_expr & " - 1) .. " & blk & ":sub(" & idx_expr & " + 1)", luaPrec(".."))
  of stBlock:
    lxOther("(function() table.remove(" & blk & ", " & idx_expr & "); return " & blk & " end)()")
  of stUnknown:
    e.useHelper("_remove")
    lxCall("_remove(" & blk & ", " & idx_expr & ")"))

registerExpr("select", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let blk = e.emitExpr(vals, pos)
  let key = e.emitExpr(vals, pos)
  e.useHelper("_select")
  e.useHelper("_equals")
  lxCall("_select(" & blk & ", " & key & ")"))

registerExpr("has?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  # Peek at needle AST to detect scalar literals
  let isScalar = pos + 1 < vals.len and
    (vals[pos + 1].kind in {vkString, vkInteger, vkFloat} or
     (vals[pos + 1].kind == vkWord and vals[pos + 1].wordKind == wkWord and
      vals[pos + 1].wordName in ["true", "false"]))
  let seqType = e.inferSeqType(vals, pos)
  let blk = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  # String: substring search — paren-wrapped already.
  if seqType == stString:
    return lxCall("(string.find(" & blk & ", " & val_expr & ", 1, true) ~= nil)")
  if isScalar:
    # Inline loop with == for scalars — no need for _equals
    lxOther("(function() for _, x in ipairs(" & blk & ") do if x == " & val_expr &
      " then return true end end return false end)()")
  else:
    e.useHelper("_has")
    e.useHelper("_equals")
    lxCall("_has(" & blk & ", " & val_expr & ")"))

# --- String operations ---
registerExpr("split", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let str = e.emitExpr(vals, pos)
  let delim = e.emitExpr(vals, pos)
  e.useHelper("_split")
  lxCall("_split(" & str & ", " & delim & ")"))

registerExpr("replace", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let str = e.emitExpr(vals, pos)
  let old = e.emitExpr(vals, pos)
  let new_str = e.emitExpr(vals, pos)
  e.useHelper("_replace")
  lxCall("_replace(" & str & ", " & old & ", " & new_str & ")"))

registerExpr("byte", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxCall("string.byte(" & e.emitExpr(vals, pos) & ", 1)"))

registerExpr("char", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxCall("string.char(" & e.emitExpr(vals, pos) & ")"))

registerExpr("starts-with?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let str = e.emitExpr(vals, pos)
  let prefix = e.emitExpr(vals, pos)
  lxCall("(string.sub(" & str & ", 1, #" & prefix & ") == " & prefix & ")"))

registerExpr("ends-with?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let str = e.emitExpr(vals, pos)
  let suffix = e.emitExpr(vals, pos)
  lxCall("(string.sub(" & str & ", -#" & suffix & ") == " & suffix & ")"))

registerExpr("subset", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let seqType = e.inferSeqType(vals, pos)
  let str = e.emitExpr(vals, pos)
  let start = e.emitExpr(vals, pos)
  let length = e.emitExpr(vals, pos)
  case seqType
  of stString:
    lxCall("string.sub(" & str & ", " & start & ", " & start & " + " & length & " - 1)")
  of stBlock:
    # Inline block slice — no helper
    lxOther("(function() local r={} local _t=" & str & " local _s=" & start & " local _n=math.min(_s+" & length & "-1, #_t) for _i=_s,_n do r[#r+1]=_t[_i] end return r end)()")
  of stUnknown:
    e.useHelper("_subset")
    lxCall("_subset(" & str & ", " & start & ", " & length & ")"))

# --- random ---
# `random N` emits `math.random() * N`, a multiplication at prec 6.
registerExpr("random", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  e.usedRandom = true
  lxInfix("math.random() * " & e.emitExpr(vals, pos), luaPrec("*")))

registerExpr("random/int", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  e.usedRandom = true
  let n = e.emitExpr(vals, pos)
  lxCall("math.random(" & n & ")"))

registerExpr("random/int/range", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  e.usedRandom = true
  let lo = e.emitExpr(vals, pos)
  let hi = e.emitExpr(vals, pos)
  lxCall("math.random(" & lo & ", " & hi & ")"))

registerExpr("random/choice", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  e.usedRandom = true
  let blk = e.emitExpr(vals, pos)
  lxOther("(function() local _t = " & blk & "; return _t[math.random(#_t)] end)()"))

registerExpr("random/seed", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  e.usedRandom = true
  lxCall("math.randomseed(" & e.emitExpr(vals, pos) & ")"))

# --- Type conversion ---
registerExpr("to", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let typeExpr = e.emitExpr(vals, pos)
  let val_expr = e.emitExpr(vals, pos)
  if typeExpr == "\"string!\"": lxCall("tostring(" & val_expr & ")")
  elif typeExpr == "\"integer!\"": lxCall("math.floor(tonumber(" & val_expr & "))")
  elif typeExpr == "\"float!\"": lxCall("tonumber(" & val_expr & ")")
  else: lxInfix("tonumber(" & val_expr & ") or " & val_expr, luaPrec("or")))

# --- Type introspection ---
registerExpr("type", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxCall("type(" & e.emitExpr(vals, pos) & ")"))

# --- error: raise a tagged error table so catch handlers can dispatch on kind ---
registerExpr("error", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let kind = e.emitExpr(vals, pos)
  let msg = e.emitExpr(vals, pos)
  let data = e.emitExpr(vals, pos)
  lxCall("error({kind = " & kind & ", msg = " & msg & ", data = " & data & "})"))

# --- sort ---
registerExpr("sort", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let seqType = e.inferSeqType(vals, pos)
  let arg = e.emitExpr(vals, pos)
  case seqType
  of stString:
    lxOther("(function() local t = {} for i = 1, #" & arg & " do t[i] = " & arg & ":sub(i,i) end table.sort(t) return table.concat(t) end)()")
  of stBlock:
    lxOther("(function() table.sort(" & arg & "); return " & arg & " end)()")
  of stUnknown:
    e.useHelper("_sort")
    lxCall("_sort(" & arg & ")"))

# --- apply ---
registerExpr("apply", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let fn = e.emitExpr(vals, pos)
  let args_expr = e.emitExpr(vals, pos)
  e.usedVariadicUnpack = true
  lxCall(fn & "(unpack(" & args_expr & "))"))

# --- reduce (passthrough) — returns whatever shape the inner expression has.
# Since `reduce` is a no-op in compiled output, tag as `lxOther` to preserve
# conservative wrap behavior; a typed passthrough would require emitExpr to
# return LuaExpr which happens in Phase C.4.
registerExpr("reduce", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxOther(e.emitExpr(vals, pos)))

# --- all/any: short-circuit boolean combinators. Paren-wrapped outputs
# compose safely; tag as lxCall so `paren` leaves them alone.
registerExpr("all?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    var parts: seq[string] = @[]
    var bpos = 0
    while bpos < blk.len:
      parts.add(e.emitExpr(blk, bpos))
    lxCall("(" & parts.join(" and ") & ")")
  else:
    lxLit("true"))

registerExpr("any?", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    var parts: seq[string] = @[]
    var bpos = 0
    while bpos < blk.len:
      parts.add(e.emitExpr(blk, bpos))
    lxCall("(" & parts.join(" or ") & ")")
  else:
    lxLit("false"))

# --- merge: create new table with entries from both sources ---
registerExpr("merge", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let a = e.emitExpr(vals, pos, primary = true)
  let b = e.emitExpr(vals, pos, primary = true)
  lxOther("(function() local r = {} for k, v in pairs(" & a & ") do r[k] = v end for k, v in pairs(" & b & ") do r[k] = v end return r end)()"))

# --- object: emit as table with field defaults and methods ---
registerExpr("object", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
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
      result = lxTableCtor("{}")
    else:
      result = lxTableCtor("{\n" & parts.mapIt(repeat("  ", e.indent + 1) & it).join(",\n") & "\n" & e.pad & "}")
  else:
    result = lxTableCtor("{}"))

# --- make: emit inline table merging object defaults with overrides ---
registerExpr("make", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
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
      return lxCall("_make(" & objExpr & ", " & overridesExpr & ", \"" & objName & "\")")
    else:
      return lxCall("_make(" & objExpr & ", " & overridesExpr & ")")
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
      lxTableCtor("{}")
    else:
      lxTableCtor("{\n" & parts.mapIt(repeat("  ", e.indent + 1) & it).join(",\n") & "\n" & e.pad & "}")
  else:
    # Unknown object - fall back to _make (prototype table needed at runtime)
    e.useHelper("_make")
    discard  # prototype needed at runtime
    let overridesExpr = "{" & overrides.mapIt(it.name & " = " & it.value).join(", ") & "}"
    if objName in e.customTypes:
      lxCall("_make(" & objExpr & ", " & overridesExpr & ", \"" & objName & "\")")
    else:
      lxCall("_make(" & objExpr & ", " & overridesExpr & ")"))

# --- exports: handled at module level, skip in expression context ---
registerExpr("exports", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  discard e.emitExpr(vals, pos)  # consume the block arg
  lxLit("nil"))

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

proc emitScope(e: var LuaEmitter, blk: seq[KtgValue], asExpr: bool): string =
  ## Emit a `scope [...]` block in either statement form (`do ... end`)
  ## or expression form (`(function() ... end)()`). The expression form
  ## uses an IIFE so the body's implicit return becomes the scope's value.
  ## Shared between stmtHandlers["scope"] and emitExpr's scope branch.
  let savedLocals = e.locals
  e.locals = initHashSet[string]()
  if asExpr:
    e.indent += 1
    let bodyStr = withCapture(e):
      e.emitBlock(blk, asReturn = true)
    e.indent -= 1
    e.locals = savedLocals
    return "(function()\n" & bodyStr & e.pad & "end)()"
  else:
    e.ln("do")
    e.indent += 1
    e.emitBlock(blk)
    e.indent -= 1
    e.locals = savedLocals
    e.ln("end")
    return ""

# scope — statement with block scoping and locals save/restore
stmtHandlers["scope"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    discard e.emitScope(blk, asExpr = false)

## (isInfixOp lives in helpers.nim.)

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
    if e.hasVarSeqType(lname):
      return e.varSeqType(lname)
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

## (luaOp, luaPrec, emitPath live in helpers.nim.)

# ---------------------------------------------------------------------------
# Emit a single literal value as a Lua expression string
# ---------------------------------------------------------------------------

proc emitLiteral(e: var LuaEmitter, val: KtgValue): string =
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
    e.useHelper("_NONE")
    "_NONE"
  of vkMoney:
    # Emit via metatable helper so arithmetic, comparison, print and concat
    # match the interpreter ($12.34 formatting). Integer cents representation
    # lives inside the `cents` field; arithmetic is metamethod-dispatched.
    e.useHelper("_money")
    "_money(" & $val.cents & ")"
  of vkPair:
    # Emit via metatable helper so arithmetic ops work
    e.useHelper("_pair")
    "_pair(" & pairComp(val.px) & ", " & pairComp(val.py) & ")"
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
  ## Uses _NONE instead of nil to preserve array indices only when the
  ## program uses `none?` (and therefore needs the sentinel to distinguish).
  var parts: seq[string] = @[]
  var pos = 0
  while pos < vals.len:
    let expr = e.emitExpr(vals, pos)
    if expr == "nil" and e.programUsesNoneCheck:
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

## (customTypeBase lives in helpers.nim.)

proc emitCustomTypeParamGuards(e: var LuaEmitter, spec: ParsedFuncSpec) =
  ## Emit runtime guard checks for params annotated with a custom @type.
  ## Matches interpreter semantics: calling the function with a value that
  ## fails the type's guard errors at call time with "<name> expects
  ## <type>!, got <actual>". Primitive-typed params (integer!, string!,
  ## etc.) are intentionally skipped here — they are a separate gap.
  for ps in spec.params:
    if ps.typeName.len == 0: continue
    let base = customTypeBase(ps.typeName)
    if base in e.customTypeRules:
      e.usedTypeChecks.incl(base)
      let predName = customTypePredicateName(base)
      let paramLua = luaName(ps.name)
      e.ln("if not " & predName & "(" & paramLua & ") then")
      e.ln("  error(\"" & ps.name & " expects " & ps.typeName &
           ", got \" .. type(" & paramLua & "))")
      e.ln("end")

# ---------------------------------------------------------------------------
# Emit function definition
# ---------------------------------------------------------------------------

proc emitFuncDef(e: var LuaEmitter, specBlock, bodyBlock: seq[KtgValue]): string =
  ## Parse a function spec [a b] and body [...] into a Lua function expression.
  let spec = parseFuncSpec(specBlock)
  let params = spec.allLuaParams()

  let paramStr = params.join(", ")
  var funcStr = "function(" & paramStr & ")\n"

  # Save and reset per-scope state for the new function scope. bindings
  # is intentionally kept (prescan is global); locals + varTable are the
  # per-fn state that gets restored on exit.
  let savedLocals = e.locals
  let savedVarTable = e.varTable
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
      if kebab in e.objectFields or kebab == "money":
        # Track object types (for make / rejoin field-awareness) and money
        # (so `abs` can reject money args at compile time).
        e.setVarType(ps.name, kebab)
      if ps.typeName in SafeConcatTypes:
        e.markConcatSafe(luaName(ps.name))
      if ps.typeName == "string!":
        e.setVarSeqType(luaName(ps.name), stString)
      elif ps.typeName == "block!":
        e.setVarSeqType(luaName(ps.name), stBlock)

  # A custom-@type return annotation triggers a runtime guard wrap.
  # Primitive return types are intentionally not enforced here — they
  # are the same gap noted in emitCustomTypeParamGuards.
  let returnGuardBase =
    if spec.returnType.len > 0:
      let base = customTypeBase(spec.returnType)
      if base in e.customTypeRules: base
      else: ""
    else: ""

  e.indent += 1
  # Emit body — last expression is implicit return. Param guard checks
  # run before the body so a failing arg errors with a useful
  # "<param> expects <type>!, got <actual>" message instead of a
  # misleading downstream type error.
  let paramGuardStr = withCapture(e):
    e.emitCustomTypeParamGuards(spec)
  var bodyStr: string
  if returnGuardBase.len > 0:
    e.usedTypeChecks.incl(returnGuardBase)
    e.useHelper("_check_ret")
    let predName = customTypePredicateName(returnGuardBase)
    let suffix = ", " & predName & ", \"" & spec.returnType & "\")"
    if isPureExpressionBody(bodyBlock):
      var bpos = 0
      let expr = e.emitExpr(bodyBlock, bpos)
      bodyStr = paramGuardStr & e.pad & "return _check_ret(" & expr & suffix & "\n"
    else:
      e.indent += 1
      let innerStr = withCapture(e):
        e.emitBody(bodyBlock, asReturn = true)
      e.indent -= 1
      bodyStr = paramGuardStr & e.pad & "return _check_ret((function()\n"
      bodyStr &= innerStr
      bodyStr &= e.pad & "end)()" & suffix & "\n"
  else:
    let innerStr = withCapture(e):
      e.emitBody(bodyBlock, asReturn = true)
    bodyStr = paramGuardStr & innerStr
  e.indent -= 1

  e.locals = savedLocals
  e.varTable = savedVarTable

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
    if isPureExpressionBody(bodyVals):  # simple expression: emit directly
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
    if isPureExpressionBody(bodyVals):
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
    if isPureExpressionBody(bodyVals):
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

    # Variable binding block. Register iterator names as locals so the
    # body can reference them without tripping the strict-globals check.
    var vars: seq[string] = @[]
    if pos < blk.len and blk[pos].kind == vkBlock:
      for v in blk[pos].blockVals:
        if v.kind == vkWord:
          let luaVar = luaName(v.wordName)
          vars.add(luaVar)
          e.locals.incl(luaVar)
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
              let iterFn =
                if series in e.contextVars: "pairs"
                else: "ipairs"
              let varStr = if vars.len > 0: "_, " & vars[0] else: "_"
              e.ln("for " & varStr & " in " & iterFn & "(" & series & ") do")
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
      e.locals.incl("it")
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
      conditions.add(valueExpr & " == " & emitLiteral(e, p))
    of vkType:
      let base = if p.typeName.endsWith("!"):
                   p.typeName[0 ..< p.typeName.len - 1] else: p.typeName
      let kebab = base.toLower.replace("_", "-")
      if kebab in e.customTypeRules:
        # User-declared @type: route through synthesized predicate.
        e.usedTypeChecks.incl(kebab)
        conditions.add(customTypePredicateName(kebab) & "(" & valueExpr & ")")
      else:
        conditions.add("type(" & valueExpr & ") == " & ktgTypeToLuaType(p.typeName))
    of vkWord:
      if p.wordKind == wkWord and p.wordName == "_":
        discard  # wildcard — always matches
      elif p.wordKind == wkWord and p.wordName in BuiltinTypePredicates:
        conditions.add(inlineTypePredicate(p.wordName, valueExpr))
      elif p.wordKind == wkWord and p.wordName.endsWith("?"):
        # User predicate: call it with the match value.
        conditions.add(luaName(p.wordName) & "(" & valueExpr & ")")
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
        conditions.add(elemExpr & " == " & emitLiteral(e, p))
      of vkType:
        let base = if p.typeName.endsWith("!"):
                     p.typeName[0 ..< p.typeName.len - 1] else: p.typeName
        let kebab = base.toLower.replace("_", "-")
        if kebab in e.customTypeRules:
          e.usedTypeChecks.incl(kebab)
          conditions.add(customTypePredicateName(kebab) & "(" & elemExpr & ")")
        else:
          conditions.add("type(" & elemExpr & ") == " & ktgTypeToLuaType(p.typeName))
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

proc emitHandlerAsAssign(e: var LuaEmitter, handler: seq[KtgValue],
                          varName: string) =
  ## Emit a match handler body as an assignment to varName. Prefers direct
  ## `varName = <expr>` when the body is a single expression; falls back to
  ## IIFE-wrapped assignment when it's multi-statement so the final
  ## expression still lands in varName. Writes at the current indent.
  if handler.len == 0:
    e.ln(varName & " = nil")
    return
  let outSaved = e.output
  var hpos = 0
  let expr = e.emitExpr(handler, hpos)
  if hpos >= handler.len:
    e.output = outSaved
    e.ln(varName & " = " & expr)
    return
  e.output = outSaved
  e.ln(varName & " = (function()")
  e.indent += 1
  e.emitBlock(handler, asReturn = true)
  e.indent -= 1
  e.ln("end)()")

type MatchSink* = enum
  msStmt        ## `match v [...]` as a statement; handlers are plain blocks
  msStmtReturn  ## same, but handlers get asReturn (trailing implicit return)
  msExpr        ## `match v [...]` as an expression; wraps in IIFE
  msAssign      ## `x: match v [...]`; handlers assign to varName (no IIFE)

proc emitMatch(e: var LuaEmitter, valueExpr: string,
               rulesBlock: seq[KtgValue], sink: MatchSink,
               varName: string = ""): string =
  ## Unified match emission. Replaces the older emitMatchStmt /
  ## emitMatchExpr / emitMatchHoisted trio. Shape differences between
  ## sinks are localized to small per-sink case branches; the pattern
  ## parsing, binding registration, guard evaluation, and condition
  ## composition are shared.
  ##
  ## Returns a Lua string only when sink is msExpr (caller composes it
  ## into a larger expression); other sinks write directly to e.output.
  var pos = 0
  var first = true
  var code = ""
  let baseIndent = e.pad
  if sink == msExpr:
    code = "(function()\n"

  template openBranch(keyword, cond: string) =
    case sink
    of msExpr:
      code &= baseIndent & "  " & keyword & " " & cond & " then\n"
    else:
      e.ln(keyword & " " & cond & " then")

  template openElse() =
    case sink
    of msExpr:
      code &= baseIndent & "  else\n"
    else:
      e.ln("else")

  template emitBinding(name, expr: string) =
    case sink
    of msExpr:
      code &= baseIndent & "    local " & name & " = " & expr & "\n"
    else:
      e.ln("local " & name & " = " & expr)
    e.locals.incl(name)

  template emitHandlerBody(handler: seq[KtgValue]) =
    case sink
    of msStmt:
      e.emitBlock(handler)
    of msStmtReturn:
      e.emitBlock(handler, asReturn = true)
    of msExpr:
      let savedIndent = e.indent
      e.indent = e.indent + 2
      let captured = withCapture(e):
        e.emitBody(handler, asReturn = true)
      code &= captured
      e.indent = savedIndent
    of msAssign:
      e.emitHandlerAsAssign(handler, varName)

  while pos < rulesBlock.len:
    let current = rulesBlock[pos]

    # --- default handler ---
    if current.kind == vkWord and current.wordKind == wkWord and
       current.wordName == "default":
      pos += 1
      if pos < rulesBlock.len and rulesBlock[pos].kind == vkBlock:
        let handler = rulesBlock[pos].blockVals
        pos += 1
        let savedLocals = e.locals
        if first:
          # First/only branch. Each sink needs its own "no-conditional"
          # wrapper: stmt forms use `do ... end` to keep block-scoped
          # locals consistent; expr mode already sits inside the IIFE;
          # assign mode emits at caller indent with no wrapper.
          case sink
          of msStmt, msStmtReturn:
            e.ln("do")
            e.indent += 1
            emitHandlerBody(handler)
            e.indent -= 1
            e.ln("end")
          of msExpr, msAssign:
            emitHandlerBody(handler)
        else:
          openElse()
          e.indent += 1
          emitHandlerBody(handler)
          e.indent -= 1
        e.locals = savedLocals
        first = false
      continue

    # --- expect pattern block ---
    if current.kind != vkBlock:
      pos += 1
      continue

    let pattern = current.blockVals
    pos += 1

    # Build pattern conditions + bindings FIRST so the guard can
    # reference captured names without tripping strict-globals.
    var conditions: seq[string] = @[]
    var bindings: seq[(string, string)] = @[]
    e.buildPatternMatch(pattern, valueExpr, conditions, bindings)
    let savedLocalsForGuard = e.locals
    for (bname, _) in bindings:
      e.locals.incl(bname)

    # Optional `when` guard (sees pattern bindings).
    var guardExpr = ""
    if pos < rulesBlock.len and rulesBlock[pos].kind == vkWord and
       rulesBlock[pos].wordKind == wkWord and rulesBlock[pos].wordName == "when":
      pos += 1
      if pos < rulesBlock.len and rulesBlock[pos].kind == vkBlock:
        var gpos = 0
        guardExpr = e.emitExpr(rulesBlock[pos].blockVals, gpos)
        pos += 1
    e.locals = savedLocalsForGuard

    if pos >= rulesBlock.len or rulesBlock[pos].kind != vkBlock:
      continue
    let handler = rulesBlock[pos].blockVals
    pos += 1

    if guardExpr.len > 0:
      conditions.add(guardExpr)

    let condStr = if conditions.len > 0: conditions.join(" and ") else: ""
    if condStr.len == 0 and not first:
      openElse()
    else:
      let keyword = if first: "if" else: "elseif"
      let cond = if condStr.len > 0: condStr else: "true"
      openBranch(keyword, cond)
    e.indent += 1

    for (name, expr) in bindings:
      emitBinding(name, expr)

    let savedLocals = e.locals
    emitHandlerBody(handler)
    e.locals = savedLocals
    e.indent -= 1
    first = false

  if not first:
    case sink
    of msExpr:
      code &= baseIndent & "  end\n"
    else:
      e.ln("end")

  if sink == msExpr:
    code &= baseIndent & "end)()"
    return code
  ""

# Thin compat shims — call sites will migrate incrementally to emitMatch
# directly in a later pass. Keeping these avoids a huge call-site diff
# alongside the structural change.
proc emitMatchStmt(e: var LuaEmitter, valueExpr: string,
                    rulesBlock: seq[KtgValue], asReturn: bool = false) =
  discard e.emitMatch(valueExpr, rulesBlock,
                      if asReturn: msStmtReturn else: msStmt)
proc emitMatchExpr(e: var LuaEmitter, valueExpr: string,
                    rulesBlock: seq[KtgValue]): string =
  e.emitMatch(valueExpr, rulesBlock, msExpr)
proc emitMatchHoisted(e: var LuaEmitter, varName: string, valueExpr: string,
                      rulesBlock: seq[KtgValue]) =
  discard e.emitMatch(valueExpr, rulesBlock, msAssign, varName)

# --- Statement-form control flow registrations ------------------------------
# Registered in stmtHandlers so emitBlock's main dispatch finds them before
# falling through to the elif chain. Consulted at emitBlock line near the
# stmtHandlers lookup.

stmtHandlers["if"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  # Special case: `if has? blk needle` with scalar needle compiles to a
  # hoisted loop instead of the helper + IIFE form emitted for the generic
  # `has?` expression handler. Avoids an unnecessary function call.
  var cond: string
  if pos < vals.len and vals[pos].kind == vkWord and vals[pos].wordKind == wkWord and
     vals[pos].wordName == "has?":
    let savedPos = pos
    pos += 1
    var peekPos = pos
    if peekPos < vals.len: peekPos += 1
    let isScalar = peekPos < vals.len and
      vals[peekPos].kind in {vkString, vkInteger, vkFloat}
    if isScalar:
      let blk = e.emitExpr(vals, pos)
      let needle = e.emitExpr(vals, pos)
      e.ln("local _has_r = false")
      e.ln("for _, x in ipairs(" & blk & ") do if x == " & needle &
           " then _has_r = true; break end end")
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

stmtHandlers["either"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
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

stmtHandlers["unless"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  let cond = e.emitExpr(vals, pos)
  if pos < vals.len and vals[pos].kind == vkBlock:
    let body = vals[pos].blockVals
    pos += 1
    e.ln("if not (" & cond & ") then")
    e.indent += 1
    e.emitBlock(body)
    e.indent -= 1
    e.ln("end")

stmtHandlers["loop"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    discard e.emitLoop(blk)

stmtHandlers["match"] = proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int) =
  let valueExpr = e.emitExpr(vals, pos)
  if pos < vals.len and vals[pos].kind == vkBlock:
    let rulesBlock = vals[pos].blockVals
    pos += 1
    e.emitMatchStmt(valueExpr, rulesBlock)

# --- Expression-form control flow / dialect registrations -------------------

registerExpr("scope", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    lxOther(e.emitScope(blk, asExpr = true))
  else:
    lxLit("nil"))

registerExpr("loop", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    let loopCode = withCapture(e):
      discard e.emitLoop(blk)
    e.raw(loopCode)
    lxLit("nil")
  else:
    lxLit("nil"))

registerExpr("attempt", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let pipelineBlk = vals[pos].blockVals
    pos += 1
    lxOther(e.emitAttemptExpr(pipelineBlk))
  else:
    lxLit("nil"))

registerExpr("match", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let valueExpr = e.emitExpr(vals, pos)
  if pos < vals.len and vals[pos].kind == vkBlock:
    let rulesBlock = vals[pos].blockVals
    pos += 1
    lxOther(e.emitMatchExpr(valueExpr, rulesBlock))
  else:
    lxLit("nil"))

registerExpr("rejoin/with", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
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
        e.useHelper("_prettify")
        parts.add("_prettify(" & elem & ")")
    lxCall("table.concat({" & parts.join(", ") & "}, " & delim & ")")
  else:
    let arg = e.emitExpr(vals, pos)
    let delim = e.emitExpr(vals, pos)
    lxCall("table.concat(" & arg & ", " & delim & ")"))

registerExpr("rejoin", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  if pos < vals.len and vals[pos].kind == vkBlock:
    let blk = vals[pos].blockVals
    pos += 1
    var parts: seq[string] = @[]
    var bpos = 0
    while bpos < blk.len:
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
          fieldSafe = e.varConcatSafe(luaName(wordName))
      if not fieldSafe and bpos < blk.len and blk[bpos].kind == vkParen:
        let pvals = blk[bpos].parenVals
        for pv in pvals:
          if pv.kind == vkOp or
             (pv.kind == vkWord and pv.wordKind == wkWord and
              pv.wordName in ["+", "-", "*", "/"]):
            fieldSafe = true
            break
        if not fieldSafe and pvals.len >= 1 and pvals[0].kind == vkWord and
           pvals[0].wordKind == wkWord and
           pvals[0].wordName in e.funcReturnTypes and
           e.funcReturnTypes[pvals[0].wordName] in SafeConcatTypes:
          fieldSafe = true
      let elem = e.emitExpr(blk, bpos)
      let needsWrap = not (
        fieldSafe or
        elem.startsWith("\"") or
        elem.startsWith("(") or
        (elem.len > 0 and elem[0] in {'0'..'9', '-'})
      )
      if needsWrap:
        e.useHelper("_prettify")
        parts.add("_prettify(" & elem & ")")
      else:
        parts.add(elem)
    var merged: seq[string] = @[]
    for p in parts:
      if merged.len > 0 and merged[^1].endsWith("\"") and p.startsWith("\""):
        merged[^1] = merged[^1][0..^2] & p[1..^1]
      else:
        merged.add(p)
    if merged.len == 1: lxOther(merged[0])
    else: lxInfix(merged.join(" .. "), luaPrec(".."))
  else:
    let arg = e.emitExpr(vals, pos)
    lxCall("table.concat(" & arg & ")"))

registerExpr("find", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let seqType = e.inferSeqType(vals, pos)
  let series = e.emitExpr(vals, pos)
  let needle = e.emitExpr(vals, pos)
  case seqType
  of stString:
    lxCall("(string.find(" & series & ", " & needle & ", 1, true))")
  of stBlock:
    e.useHelper("_equals")
    lxOther("(function() for i, v in ipairs(" & series & ") do if _equals(v, " & needle & ") then return i end end return nil end)()")
  of stUnknown:
    e.useHelper("_equals")
    lxOther("(function() " &
      "if type(" & series & ") == \"string\" then " &
      "local i = string.find(" & series & ", " & needle & ", 1, true); " &
      "if i then return i end; return nil " &
      "else " &
      "for i, v in ipairs(" & series & ") do if _equals(v, " & needle & ") then return i end end; return nil " &
      "end " &
      "end)()"))

registerExpr("reverse", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let seqType = e.inferSeqType(vals, pos)
  let argTyped = e.emitExprTyped(vals, pos)
  let a = paren(argTyped, 0)
  case seqType
  of stString:
    lxCall("string.reverse(" & a & ")")
  of stBlock:
    lxOther("(function() local _t=" & a & "; local r={}; for i=#_t,1,-1 do r[#r+1]=_t[i] end; return r end)()")
  of stUnknown:
    lxOther("(function() " &
      "if type(" & a & ") == \"string\" then return string.reverse(" & a & ") " &
      "else local _t=" & a & "; local r={}; for i=#_t,1,-1 do r[#r+1]=_t[i] end; return r end " &
      "end)()"))

registerExpr("if", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let cond = e.emitExpr(vals, pos)
  if pos < vals.len and vals[pos].kind == vkBlock:
    let bodyBlock = vals[pos].blockVals
    pos += 1
    e.indent += 1
    let bodyOut = withCapture(e):
      e.emitBody(bodyBlock, asReturn = true)
    e.indent -= 1
    lxOther("(function()\n" & e.pad & "  if " & cond & " then\n" &
      bodyOut &
      e.pad & "  end\n" & e.pad & "end)()")
  else:
    lxLit("nil"))

registerExpr("either", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  let cond = e.emitExpr(vals, pos)
  var trueBlock: seq[KtgValue] = @[]
  var falseBlock: seq[KtgValue] = @[]
  if pos < vals.len and vals[pos].kind == vkBlock:
    trueBlock = vals[pos].blockVals
    pos += 1
  if pos < vals.len and vals[pos].kind == vkBlock:
    falseBlock = vals[pos].blockVals
    pos += 1
  lxOther(e.emitEitherExpr(cond, trueBlock, falseBlock)))

# Loop refinements — fixed names, registered explicitly so the wkWord arm
# dispatch doesn't need a pattern-match branch.
for refinement in ["collect", "fold", "partition"]:
  let refName = refinement  # closure capture
  registerExpr("loop/" & refinement, proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
    if pos < vals.len and vals[pos].kind == vkBlock:
      let blk = vals[pos].blockVals
      pos += 1
      e.indent += 1
      let loopCode = withCapture(e):
        let resultVar = e.emitLoop(blk, refName)
        e.ln("return " & resultVar)
      e.indent -= 1
      lxOther("(function()\n" & loopCode & e.pad & "end)()")
    else:
      lxLit("nil"))

proc importHandlerImpl(e: var LuaEmitter, vals: seq[KtgValue], pos: var int,
                       name: string): string =
  if pos >= vals.len: return "nil"
  # Stdlib import (lit-word): route module + symbol set into the
  # prelude. The actual fns live in prelude.lua as globals; this
  # call site emits nothing. Also prescan the imported fns into
  # e.bindings so subsequent call sites know their arity and
  # strict-globals accepts them as known names.
  if vals[pos].kind == vkWord and vals[pos].wordKind == wkLitWord:
    let moduleName = vals[pos].wordName
    pos += 1
    if moduleName notin e.usedStdlibSymbols:
      e.usedStdlibSymbols[moduleName] = initHashSet[string]()
    var symList: seq[string]
    if name == "import/using" and pos < vals.len and
       vals[pos].kind == vkBlock:
      for sym in vals[pos].blockVals:
        if sym.kind == vkWord:
          e.usedStdlibSymbols[moduleName].incl(sym.wordName)
          symList.add(sym.wordName)
      pos += 1
    else:
      e.usedStdlibSymbols[moduleName].incl("*")
      symList = moduleExports(moduleName)
    let fnsAst = spliceSelectedFunctions(moduleName, symList)
    if fnsAst.len > 0:
      e.prescanBlock(fnsAst)
    return ""
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
    let srcDir = if e.sourceDir.len > 0: e.sourceDir else: getCurrentDir()
    let absPath = if rawPath.isAbsolute: rawPath else: srcDir / rawPath
    if absPath in e.compiling:
      raise EmitError(msg: "circular require detected: " & rawPath)
    let moduleName = rawPath.changeFileExt("").replace("/", ".").replace("\\", ".")
    if fileExists(absPath):
      let depSource = readFile(absPath)
      var depAst = parseSource(depSource)
      if depAst.len >= 2 and depAst[0].kind == vkWord and depAst[0].wordKind == wkWord and
         depAst[0].wordName.startsWith("Kintsugi") and depAst[1].kind == vkBlock:
        depAst = depAst[2..^1]
      let outPath = absPath.changeFileExt("lua")
      var childCompiling = e.compiling
      childCompiling.incl(absPath)
      let depDir = parentDir(absPath)
      let (depLua, depE) = emitLuaModuleEx(depAst, depDir, childCompiling, e.eval, e.target)
      e.pendingDepWrites.add((path: outPath, lua: depLua))
      for (p, l) in depE.pendingDepWrites:
        e.pendingDepWrites.add((path: p, lua: l))
      for h in depE.usedHelpers: e.usedHelpers.incl(h)
      for t in depE.usedTypeChecks: e.usedTypeChecks.incl(t)
      for k, v in depE.customTypeRules:
        if k notin e.customTypeRules:
          e.customTypeRules[k] = v
      for k, v in depE.usedStdlibSymbols:
        if k notin e.usedStdlibSymbols:
          e.usedStdlibSymbols[k] = initHashSet[string]()
        for s in v: e.usedStdlibSymbols[k].incl(s)
      if depE.usedRandom: e.usedRandom = true
      if depE.usedVariadicUnpack: e.usedVariadicUnpack = true
      if depE.programUsesNoneCheck: e.programUsesNoneCheck = true
    "require(\"" & moduleName & "\")"

registerExpr("import", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxOther(importHandlerImpl(e, vals, pos, "import")))

registerExpr("import/using", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  lxOther(importHandlerImpl(e, vals, pos, "import/using")))

registerExpr("capture", proc(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): LuaExpr =
  # Parse schema (second arg) at compile time to get keyword names
  let dataStart = pos
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
    var specParts: seq[string] = @[]
    for (kw, exact) in specs:
      if exact >= 0:
        specParts.add("{\"" & kw & "\", " & $exact & "}")
      else:
        specParts.add("\"" & kw & "\"")
    let specStr = "{" & specParts.join(", ") & "}"
    if pos < vals.len and vals[pos].kind == vkBlock:
      pos += 1
    e.useHelper("_capture")
    lxCall("_capture(" & dataStr & ", " & specStr & ")")
  else:
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
      lxCall("_capture(" & dataExpr & ", {" & specParts.join(", ") & "})")
    else:
      lxLit("nil"))

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

  # Sourceless attempt compiles to a reusable `function(it) ... end`
  # matching the interpreter's arity-1 closure (src/dialects/attempt_dialect.nim).
  # Sourced attempt runs immediately via `(function() ... end)()`.
  let baseIndent = e.pad
  let savedIndent = e.indent
  var code =
    if hasSource: "(function()\n"
    else: "function(it)\n"

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

  # Register `it` as a local so pipeline-step bodies can reference it
  # without tripping strict-globals. Emitted literally below.
  e.locals.incl("it")
  # Source: local it = <expr>. Sourceless shadows the outer `it` parameter
  # so pipeline-step reassignments stay local to the pcall closure.
  if not hasSource:
    pcallBody &= innerIndent & "local it = it\n"
  else:
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

  let closer = if hasSource: "end)()" else: "end"
  code &= baseIndent & closer
  e.indent = savedIndent
  result = code


# ---------------------------------------------------------------------------
# Shared path-access / path-call resolver
# ---------------------------------------------------------------------------

type PathResolution = object
  lua: string          ## The resolved Lua expression.
  isFullCall: bool     ## True when the whole path was a known binding call
                       ## (eligible for emitMethodChain wrapping at stmt
                       ## position). False for refinement calls and value
                       ## field access.

proc resolvePathCall(e: var LuaEmitter, name: string, line: int,
                     vals: seq[KtgValue], pos: var int): PathResolution =
  ## Resolve an `obj/field/sub` name into the emitted Lua expression.
  ## Shared between emitExpr's path branch and emitBlock's stmt path
  ## branch — both needed the same dispatch. Strict-globals gates the
  ## head when neither the full path nor the head is a known binding.
  let parts = name.split('/')
  let head = parts[0]
  let path = emitPath(name)
  let fullBinding = e.getBinding(name)
  let headBinding = e.getBinding(head)
  if fullBinding.isUnknown and headBinding.isUnknown:
    e.assertKnownName(head, line)
  if fullBinding.isFunction and not fullBinding.isUnknown:
    var args: seq[string] = @[]
    for i in 0 ..< fullBinding.arity:
      args.add(e.emitExpr(vals, pos))
    PathResolution(lua: path & "(" & args.join(", ") & ")", isFullCall: true)
  elif headBinding.isFunction and not headBinding.isUnknown:
    let refNames = parts[1..^1]
    var args: seq[string] = @[]
    for i in 0 ..< headBinding.arity:
      args.add(e.emitExpr(vals, pos))
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
    PathResolution(lua: e.resolvedName(head) & "(" & args.join(", ") & ")",
                   isFullCall: false)
  else:
    PathResolution(lua: path, isFullCall: false)

# ---------------------------------------------------------------------------
# Core expression emitter — returns a Lua expression string
# ---------------------------------------------------------------------------

proc emitExpr(e: var LuaEmitter, vals: seq[KtgValue], pos: var int,
              primary: bool = false): string =
  ## Back-compat projection: most call sites still concatenate strings.
  emitExprTyped(e, vals, pos, primary).text

proc emitGenericCall(e: var LuaEmitter, name: string, line: int,
                     vals: seq[KtgValue], pos: var int): LuaExpr =
  ## Fallback wkWord arm: a bare name, known function, or method call.
  ## Interpreter-only natives raise; unknown names fail the strict-globals
  ## diagnostic. A declared arity triggers a parenthesized call with default
  ## refinement args filled in (false + nils) for non-refinement invocations.
  if name in InterpreterOnlyNatives:
    compileError(name, interpreterOnlyHint(name), line)
  e.assertKnownName(name, line)
  let resolvedLua = e.resolvedName(name)
  let info = e.getBinding(name)
  let isMethod = name in e.bindingKinds and e.bindingKinds[name] == bkMethod
  let a = e.arity(name)
  if a < 0:
    return lxLit(resolvedLua)
  var args: seq[string] = @[]
  for i in 0 ..< a:
    args.add(e.emitExpr(vals, pos, primary = true))
  if info.refinements.len > 0:
    for r in info.refinements:
      args.add("false")
      for j in 0 ..< r.paramCount:
        args.add("nil")
  let callText =
    if isMethod:
      let dotPos = resolvedLua.rfind('.')
      let methodLua = resolvedLua[0..<dotPos] & ":" & resolvedLua[dotPos+1..^1]
      methodLua & "(" & args.join(", ") & ")"
    else:
      resolvedLua & "(" & args.join(", ") & ")"
  # Tag calls into user functions with a declared scalar return type as
  # lxScalar so `print`/`probe` skip the `_prettify` wrap. Kintsugi
  # scalar types map to Lua primitives that print natively.
  if name in e.funcReturnTypes and
     e.funcReturnTypes[name] in ScalarReturnTypes:
    lxScalar(callText)
  else:
    lxCall(callText)

proc emitExprTyped(e: var LuaEmitter, vals: seq[KtgValue], pos: var int,
                   primary: bool = false): LuaExpr =
  ## Emit the next expression from vals starting at pos. Returns a typed
  ## `LuaExpr` and advances pos past the consumed values. When primary=false
  ## (default), greedily consumes infix operators. When primary=true, emits
  ## only the primary expression (no infix chain).
  if pos >= vals.len:
    return lxLit("nil")

  let val = vals[pos]
  pos += 1

  case val.kind

  # --- Literals ---
  of vkInteger, vkFloat, vkString, vkLogic, vkNone, vkMoney, vkPair, vkTuple:
    result = lxLit(emitLiteral(e, val))

  # --- Block: emit as Lua table ---
  of vkBlock:
    result = lxTableCtor(e.emitBlockLiteral(val.blockVals))

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
      result = lxCall("(" & e.resolvedName(headName) & "(" & args.join(", ") & "))")
    else:
      var ppos = 0
      let innerTyped = e.emitExprTyped(pvals, ppos)
      let inner = innerTyped.text
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
        result = lxCall("(" & inner & ")")
      else:
        # Single token or pure call — inherit inner kind for best downstream
        # composition decisions.
        result = innerTyped

  # --- Op: shouldn't appear here, handled by infix ---
  of vkOp:
    result = lxLit(luaOp(val.opSymbol))

  # --- Word ---
  of vkWord:
    case val.wordKind

    of wkSetWord:
      # x: expr -> should be handled at statement level, but handle here for
      # nested contexts. Return the expression value.
      result = e.emitExprTyped(vals, pos)  # the assignment is done at statement level

    of wkGetWord:
      result = lxLit(luaName(val.wordName))

    of wkLitWord:
      result = lxLit("\"" & val.wordName & "\"")

    of wkMetaWord:
      let metaName = val.wordName
      # Interpreter-only dialect machinery: hard error.
      if metaName == "parse" or metaName.startsWith("parse/"):
        compileError("@parse",
          "the parse dialect is interpreter-only; restructure to avoid it in compiled code",
          val.line)
      if metaName == "compose" or metaName.startsWith("compose/"):
        compileError("@compose",
          "@compose is a compile-time feature; use it inside @template or @preprocess",
          val.line)
      # @enter / @exit lifecycle hooks are partitioned out by emitBlock
      # (src/core/lifecycle.nim). Reaching one at expression position
      # means it appeared outside a block context (e.g. inside a paren
      # group) where the partition pass can't see it — refuse rather
      # than silently drop.
      if metaName == "enter" or metaName == "exit":
        compileError("@" & metaName,
          "@" & metaName & " must appear at block statement position " &
          "(module, function body, scope block); not valid in a paren " &
          "group or expression position.",
          val.line)
      # Type-system meta-words are consumed by prescan (`name!: @type ...`,
      # `name: @type/guard ...`). Reaching them at expression position means
      # the form was malformed (e.g. an `@type` not in a set-word RHS). Emit
      # nothing rather than `nil` — predicates are looked up by name.
      if metaName == "type" or metaName.startsWith("type/"):
        result = lxLit("")
      elif metaName == "const":
        result = lxLit("")
      else:
        # Unknown meta-words (@template, @inline, @preprocess) - silently
        # erase. Compile-time machinery handles these elsewhere.
        result = lxLit("")

    of wkWord:
      let name = val.wordName
      # Skip handler dispatch if name has been user-assigned as a value
      # (prescan found `name: expr` where expr isn't a function).
      let userAssigned = name in e.bindings and
        not e.bindings[name].isFunction and not e.bindings[name].isUnknown
      if name in exprHandlers and not userAssigned:
        result = exprHandlers[name](e, vals, pos)
      elif name.startsWith("system/env/"):
        result = lxCall("os.getenv(\"" & name.split('/')[2] & "\")")
      elif name.contains('/'):
        result = lxCall(resolvePathCall(e, name, val.line, vals, pos).lua)
      else:
        result = e.emitGenericCall(name, val.line, vals, pos)

  # --- Types, files, urls, emails — emit as string literals ---
  of vkType:
    result = lxLit("\"" & val.typeName & "\"")
  of vkFile:
    result = lxLit("\"" & luaEscape(val.filePath) & "\"")
  of vkUrl:
    result = lxLit("\"" & luaEscape(val.urlVal) & "\"")
  of vkEmail:
    result = lxLit("\"" & luaEscape(val.emailVal) & "\"")

  # --- Date/Time — emit as tables ---
  of vkDate:
    result = lxTableCtor("{year=" & $val.year & ", month=" & $val.month & ", day=" & $val.day & "}")
  of vkTime:
    result = lxTableCtor("{hour=" & $val.hour & ", minute=" & $val.minute & ", second=" & $val.second & "}")

  # --- Remaining types ---
  of vkMap:
    var parts: seq[string] = @[]
    for k, v in val.mapEntries:
      parts.add(luaName(k) & " = " & emitLiteral(e, v))
    result = lxTableCtor("{" & parts.join(", ") & "}")

  of vkSet:
    var parts: seq[string] = @[]
    for m in val.setMembers:
      parts.add("[\"" & luaEscape(m) & "\"] = true")
    result = lxTableCtor("{" & parts.join(", ") & "}")

  of vkContext:
    var parts: seq[string] = @[]
    for k, v in val.ctx.entries:
      parts.add(luaName(k) & " = " & emitLiteral(e, v))
    result = lxTableCtor("{" & parts.join(", ") & "}")

  of vkObject:
    var parts: seq[string] = @[]
    for k, v in val.obj.entries:
      parts.add(luaName(k) & " = " & emitLiteral(e, v))
    result = lxTableCtor("{" & parts.join(", ") & "}")

  of vkFunction, vkNative:
    result = lxLit("nil  -- cannot emit runtime function/native value")

  # Handle infix chain — left-to-right (Kintsugi has no precedence).
  # `result` is the accumulating left operand; `paren(result, opPrec)`
  # decides wrapping from `lxInfix.prec` directly. Non-infix left operands
  # (lxLit / lxCall / lxOther / lxTableCtor) are treated as atomic by
  # `paren` — matching the previous "never wraps on first iteration" rule.
  if not primary:
    while pos < vals.len and isInfixOp(vals[pos]):
      let op = vals[pos]
      let opStr = if op.kind == vkOp: luaOp(op.opSymbol) else: luaOp(op.wordName)
      let prec = luaPrec(opStr)
      pos += 1
      let right = e.emitExpr(vals, pos, primary = true)
      # Special case: comparing to none. Routes to _is_none which accepts
      # both Kintsugi's _NONE sentinel and raw Lua nil (from native bindings,
      # missing table fields, etc.) so the comparison works regardless of
      # which side of the boundary the absent value came from.
      if right == "_NONE" and opStr == "==":
        e.useHelper("_is_none")
        result = lxCall("_is_none(" & result.text & ")")
      elif right == "_NONE" and opStr == "~=":
        e.useHelper("_is_none")
        result = lxCall("(not _is_none(" & result.text & "))")
      elif result.text == "_NONE" and opStr == "==":
        e.useHelper("_is_none")
        result = lxCall("_is_none(" & right & ")")
      elif result.text == "_NONE" and opStr == "~=":
        e.useHelper("_is_none")
        result = lxCall("(not _is_none(" & right & "))")
      else:
        result = lxInfix(paren(result, prec) & " " & opStr & " " & right, prec)

## Words that terminate `->` argument collection. `->` is specifically a
## Lua-colon-method interop operator (emits `x:method(args)`); it has no
## binding-dialect registration for external host methods (e.g. playdate
## sprites), so the emitter can't know arities and must use a syntactic
## barrier instead. Any word here marks "this is not an arg — stop."
##
## Dialect-internal keywords that aren't handlers themselves (they appear
## inside loop/attempt/match bodies) plus the explicit control-flow expr
## handlers. Statement handlers are implicitly barriers (checked via
## `stmtHandlers` lookup). Kept as a const array because module-level
## HashSets confuse the Nim JS backend's codegen.
const MethodChainBarrierNames = [
  "do", "in", "from", "to", "by", "when",
  "source", "then", "fallback", "retries", "catch", "default",
  "if", "either", "unless", "loop", "match", "try", "try/handle",
  "return", "print", "probe", "scope", "attempt", "capture",
]

proc isMethodChainBarrier(name: string): bool =
  name in MethodChainBarrierNames or name in stmtHandlers

proc emitMethodChain(e: var LuaEmitter, receiver: string,
                      vals: seq[KtgValue], pos: var int): string =
  ## Process zero or more `-> method args...` steps on `receiver`.
  ## Each step emits `:method(args)` appended to `receiver`, where args
  ## are collected until an `isMethodChainBarrier` word, another `->`, an
  ## infix op, a block, or a slashed path word (all syntactic cues that
  ## the stream has moved on to the next expression/statement).
  result = receiver
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
         isMethodChainBarrier(next.wordName): break
      if next.kind == vkWord and next.wordKind == wkWord and
         next.wordName.contains('/'): break
      if next.kind == vkBlock: break
      # Look-ahead: a bare word followed by another `->` starts the next
      # chain step on that word, not an arg to the current method.
      if next.kind == vkWord and next.wordKind == wkWord and
         pos + 1 < vals.len and vals[pos + 1].kind == vkWord and
         vals[pos + 1].wordName == "->":
        break
      args.add(e.emitExpr(vals, pos))
    result = result & ":" & methodName & "(" & args.join(", ") & ")"

proc emitExprWithChain(e: var LuaEmitter, vals: seq[KtgValue], pos: var int): string =
  ## Like emitExpr but also processes -> method chains.
  let receiver = e.emitExpr(vals, pos)
  e.emitMethodChain(receiver, vals, pos)

# ---------------------------------------------------------------------------
# Pure AST walker — mirrors emitExpr's position advancement without
# emitting anything. Used by findLastStmtStart so it can find statement
# boundaries without the side-effect hazards of dry-running the real
# emitter (helper flags, import file I/O, bindings pollution).
#
# Must stay in sync with emitExpr / emitBlock's token consumption. When a
# new handler is added, update `advanceWordCall` with its arg shape — the
# generic arity fallback only fires for pure user-bound function calls.
# ---------------------------------------------------------------------------

proc advanceExpr(e: LuaEmitter, vals: seq[KtgValue], pos: var int,
                 primary: bool = false)

proc advanceWordCall(e: LuaEmitter, vals: seq[KtgValue], pos: var int,
                     name: string) =
  ## Consume args for a `wkWord` function-call token. `pos` already past
  ## the name. Mirrors emitExpr's wkWord arm dispatch.
  if name == "none": return
  let userAssigned = name in e.bindings and
    not e.bindings[name].isFunction and not e.bindings[name].isUnknown
  if userAssigned: return

  case name

  # 0 args (constants / value-only natives)
  of "pi", "now", "system/platform", "break":
    return

  # 1 expr arg
  of "print", "probe", "return", "not", "negate", "assert",
     "abs", "sqrt", "sin", "cos", "tan", "asin", "acos", "exp",
     "log", "log10", "to-degrees", "to-radians", "floor", "ceil",
     "round", "round/up", "round/down",
     "uppercase", "lowercase", "trim", "length", "empty?",
     "integer?", "float?", "string?", "logic?", "number?", "none?",
     "block?", "context?", "object?", "map?", "function?", "native?",
     "freeze", "frozen?", "odd?", "even?",
     "first", "second", "last", "copy", "copy/deep", "reverse",
     "byte", "char", "sort", "reduce", "type", "raw", "exports",
     "random", "random/int", "random/seed", "random/choice":
    advanceExpr(e, vals, pos)

  # 2 expr args
  of "min", "max", "atan2", "pow", "is?",
     "join", "pick", "select", "has?", "split",
     "starts-with?", "ends-with?", "sort/by", "sort/with", "find",
     "random/int/range", "to", "apply", "merge",
     "append", "append/only", "remove":
    advanceExpr(e, vals, pos)
    advanceExpr(e, vals, pos)

  # 3 expr args
  of "insert", "replace", "subset", "error":
    advanceExpr(e, vals, pos)
    advanceExpr(e, vals, pos)
    advanceExpr(e, vals, pos)

  # 1 expr + 1 block
  of "if", "unless", "match":
    advanceExpr(e, vals, pos)
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1

  # 1 expr + 2 blocks
  of "either":
    advanceExpr(e, vals, pos)
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1

  # 1 block
  of "loop", "scope", "try", "does", "context", "attempt",
     "all?", "any?", "object",
     "loop/collect", "loop/fold", "loop/partition":
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1

  # 2 blocks
  of "function", "try/handle":
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1

  # Special: block-or-expr + optional follow-up
  of "rejoin":
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
    else: advanceExpr(e, vals, pos)

  of "rejoin/with":
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
    else: advanceExpr(e, vals, pos)
    advanceExpr(e, vals, pos)

  of "capture":
    # data (block-or-expr) + optional schema block
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
    else: advanceExpr(e, vals, pos)
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1

  of "make":
    # prototype-expr + (block literal | dynamic overrides expr)
    advanceExpr(e, vals, pos, primary = true)
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
    else: advanceExpr(e, vals, pos, primary = true)

  of "set":
    # set [names] rhs
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1
    advanceExpr(e, vals, pos)

  of "import":
    # module spec: lit-word or file path. One token either way.
    if pos < vals.len: pos += 1

  of "import/using":
    if pos < vals.len: pos += 1
    if pos < vals.len and vals[pos].kind == vkBlock: pos += 1

  else:
    # No explicit pattern. Handle path access, then generic arity.
    if name.startsWith("system/env/"):
      return
    if name.contains('/'):
      let parts = name.split('/')
      let head = parts[0]
      let fullBinding = e.getBinding(name)
      let headBinding = e.getBinding(head)
      if fullBinding.isFunction and not fullBinding.isUnknown:
        for i in 0 ..< fullBinding.arity:
          advanceExpr(e, vals, pos, primary = true)
      elif headBinding.isFunction and not headBinding.isUnknown:
        let refNames = parts[1..^1]
        for i in 0 ..< headBinding.arity:
          advanceExpr(e, vals, pos, primary = true)
        if headBinding.refinements.len > 0:
          for r in headBinding.refinements:
            let active = r.name in refNames
            if active:
              for j in 0 ..< r.paramCount:
                advanceExpr(e, vals, pos, primary = true)
      # else: field access, no args
      return
    # Generic user-bound function call
    let info = e.getBinding(name)
    if info.arity >= 0:
      for i in 0 ..< info.arity:
        advanceExpr(e, vals, pos, primary = true)

proc advanceExpr(e: LuaEmitter, vals: seq[KtgValue], pos: var int,
                 primary: bool = false) =
  ## Advance `pos` past one Kintsugi expression without emitting. Matches
  ## emitExpr's token consumption: primary-then-infix-chain when
  ## `primary = false`; stops after the primary when `primary = true`.
  if pos >= vals.len: return
  let val = vals[pos]
  pos += 1

  case val.kind
  of vkInteger, vkFloat, vkString, vkLogic, vkNone, vkMoney, vkPair, vkTuple,
     vkBlock, vkParen, vkOp, vkType, vkFile, vkUrl, vkEmail,
     vkDate, vkTime, vkMap, vkSet, vkContext,
     vkObject, vkFunction, vkNative:
    discard
  of vkWord:
    case val.wordKind
    of wkSetWord:
      advanceExpr(e, vals, pos)
    of wkGetWord, wkLitWord, wkMetaWord:
      discard
    of wkWord:
      advanceWordCall(e, vals, pos, val.wordName)

  # Infix chain: `a op b op c ...` continues consuming op+primary pairs.
  if not primary:
    while pos < vals.len and isInfixOp(vals[pos]):
      pos += 1
      advanceExpr(e, vals, pos, primary = true)

proc advanceMethodChain(e: LuaEmitter, vals: seq[KtgValue], pos: var int) =
  ## Advance past `-> method args ...` steps, matching emitMethodChain.
  while pos < vals.len and vals[pos].kind == vkWord and
        vals[pos].wordName == "->":
    pos += 1
    if pos >= vals.len or vals[pos].kind != vkWord: break
    pos += 1
    while pos < vals.len:
      let next = vals[pos]
      if next.kind == vkWord and next.wordName == "->": break
      if isInfixOp(next): break
      if next.kind == vkWord and next.wordKind == wkSetWord: break
      if next.kind == vkWord and next.wordKind == wkMetaWord: break
      if next.kind == vkWord and next.wordKind == wkWord and
         isMethodChainBarrier(next.wordName): break
      if next.kind == vkWord and next.wordKind == wkWord and
         next.wordName.contains('/'): break
      if next.kind == vkBlock: break
      if next.kind == vkWord and next.wordKind == wkWord and
         pos + 1 < vals.len and vals[pos + 1].kind == vkWord and
         vals[pos + 1].wordName == "->":
        break
      advanceExpr(e, vals, pos)

proc advanceExprWithChain(e: LuaEmitter, vals: seq[KtgValue],
                          pos: var int) =
  advanceExpr(e, vals, pos)
  advanceMethodChain(e, vals, pos)

# ---------------------------------------------------------------------------
# Emit a sequence of values as Lua statements
# ---------------------------------------------------------------------------

proc findLastStmtStart(e: LuaEmitter, vals: seq[KtgValue]): int =
  ## Pure AST walk: find the position of the last statement in `vals`.
  ## Uses the advanceExpr walker — no emission, no side effects, no
  ## emitter state mutation.
  var stmtStarts: seq[int] = @[]
  var pos = 0
  while pos < vals.len:
    stmtStarts.add(pos)
    let val = vals[pos]
    # Headers, bindings, exports: skip keyword + block.
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
    if val.kind == vkWord and val.wordKind == wkMetaWord and
       val.wordName == "const":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkWord and
         vals[pos].wordKind == wkSetWord:
        pos += 1
        advanceExprWithChain(e, vals, pos)
      continue
    # Set-word
    if val.kind == vkWord and val.wordKind == wkSetWord:
      pos += 1
      advanceExprWithChain(e, vals, pos)
      continue
    # Generic expression / handler dispatch — advanceExpr covers them all.
    advanceExprWithChain(e, vals, pos)
  if stmtStarts.len > 0: stmtStarts[^1] else: 0

proc emitLastWithReturn(e: var LuaEmitter, vals: seq[KtgValue]) =
  ## Emit the last statement of a block with implicit return.
  if vals.len == 0: return

  let lastVal = vals[0]

  # return/break/raw already emit themselves as statements, never as return values
  if lastVal.kind == vkWord and lastVal.wordKind == wkWord and
     lastVal.wordName in ["return", "break", "raw"]:
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

  # Partition out @enter / @exit lifecycle hooks. Matches interpreter
  # semantics (src/core/lifecycle.nim). Narrow-semantics emission: enter,
  # then body, then exit — no pcall. See roadmap-unified-dispatch-and-luaexpr
  # for the upgrade path if finally-on-error becomes needed.
  #
  # asReturn needs an IIFE so exit runs BEFORE the enclosing scope's
  # return — without it, the body's implicit return would short-circuit
  # past the exit blocks.
  let lc = partitionLifecycle(vals)
  if lc.hasHooks:
    for blk in lc.enterBlocks:
      e.emitBlock(blk)
    if asReturn:
      e.ln("local _body_result = (function()")
      e.indent += 1
      e.emitBlock(lc.body, asReturn = true)
      e.indent -= 1
      e.ln("end)()")
      for blk in lc.exitBlocks:
        e.emitBlock(blk)
      e.ln("return _body_result")
    else:
      e.emitBlock(lc.body)
      for blk in lc.exitBlocks:
        e.emitBlock(blk)
    return

  if asReturn:
    let lastStart = e.findLastStmtStart(vals)
    if lastStart > 0:
      e.emitBlock(vals[0 ..< lastStart])
    e.emitLastWithReturn(vals[lastStart .. ^1])
    return

  var pos = 0
  while pos < vals.len:
    let val = vals[pos]

    # --- raw: write string verbatim as statement, one line at a time so
    #     embedded newlines inherit the surrounding indent pad. Also
    #     scan for `local <name>` declarations so subsequent Kintsugi
    #     references to those names pass the strict-globals diagnostic.
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName == "raw":
      pos += 1
      if pos < vals.len and vals[pos].kind == vkString:
        for line in vals[pos].strVal.split('\n'):
          e.ln(line)
          # Scan each line for `local NAME` or `local NAME =` forms.
          let stripped = line.strip
          if stripped.startsWith("local "):
            var i = "local ".len
            # Collect identifier: [A-Za-z_][A-Za-z0-9_]*
            var startI = i
            while i < stripped.len and
                  (stripped[i].isAlphaNumeric or stripped[i] == '_'):
              i += 1
            if i > startI:
              e.locals.incl(stripped[startI ..< i])
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
                e.usedVariadicUnpack = true
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
          e.usedVariadicUnpack = true
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

      # @type/guard [params] [body] — emit as a regular Lua function. The
      # compileability check already ran in prescan (validateAllGuards).
      # Emission is identical to `function`; the isGuard flag is interpreter
      # state with no Lua representation.
      if pos < vals.len and vals[pos].kind == vkWord and
         vals[pos].wordKind == wkMetaWord and vals[pos].wordName == "type/guard":
        pos += 1
        if pos + 1 < vals.len and vals[pos].kind == vkBlock and
           vals[pos + 1].kind == vkBlock:
          let specBlock = vals[pos].blockVals
          let bodyBlock = vals[pos + 1].blockVals
          pos += 2
          let spec = parseFuncSpec(specBlock)
          let params = spec.allLuaParams()
          if isPath or isBound:
            e.ln(name & " = function(" & params.join(", ") & ")")
          else:
            e.ln(prefix & "function " & name & "(" & params.join(", ") & ")")
          let savedLocals = e.locals
          e.locals = savedLocals
          for n in e.moduleNames:
            e.locals.incl(n)
          for p in params:
            e.locals.incl(p)
            if p notin e.bindings:
              e.bindings[p] = BindingInfo(arity: -1, isFunction: false,
                                           isUnknown: true, isParam: true,
                                           returnArity: -1)
          e.indent += 1
          e.emitBody(bodyBlock, asReturn = not (isPath or isBound))
          e.indent -= 1
          e.locals = savedLocals
          e.ln("end")
          continue

      # @const value — emit binding with <const> annotation.
      if pos < vals.len and vals[pos].kind == vkWord and
         vals[pos].wordKind == wkMetaWord and vals[pos].wordName == "const":
        pos += 1
        let expr = e.emitExprWithChain(vals, pos)
        e.ln(prefix & name & " <const> = " & expr)
        continue

      # @type / @type/where / @type/enum — declarations are verification-only.
      # Emit nothing. Rules live in the prescan table; is? inlines them at
      # call sites.
      if pos < vals.len and vals[pos].kind == vkWord and
         vals[pos].wordKind == wkMetaWord and
         (vals[pos].wordName == "type" or vals[pos].wordName.startsWith("type/")):
        let metaName = vals[pos].wordName
        pos += 1
        if pos < vals.len and vals[pos].kind == vkBlock:
          pos += 1
          if metaName == "type/where" and pos < vals.len and
             vals[pos].kind == vkBlock:
            pos += 1
        continue

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
          let savedVarTable = e.varTable
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
              if kebab in e.objectFields or kebab == "money":
                e.setVarType(ps.name, kebab)
              if ps.typeName in SafeConcatTypes:
                e.markConcatSafe(luaName(ps.name))
              if ps.typeName == "string!":
                e.setVarSeqType(luaName(ps.name), stString)
              elif ps.typeName == "block!":
                e.setVarSeqType(luaName(ps.name), stBlock)
          # Custom-@type return annotation wraps body with a runtime guard.
          # Primitive return types mirror the param-guard gap — not enforced.
          let returnGuardBase =
            if spec.returnType.len > 0:
              let b = customTypeBase(spec.returnType)
              if b in e.customTypeRules: b
              else: ""
            else: ""
          let asRet = not (isPath or isBound or isOverride)
          e.indent += 1
          e.emitCustomTypeParamGuards(spec)
          if returnGuardBase.len > 0 and asRet:
            e.usedTypeChecks.incl(returnGuardBase)
            e.useHelper("_check_ret")
            let predName = customTypePredicateName(returnGuardBase)
            let suffix = ", " & predName & ", \"" & spec.returnType & "\")"
            if isPureExpressionBody(bodyBlock):
              var bpos = 0
              let expr = e.emitExpr(bodyBlock, bpos)
              e.ln("return _check_ret(" & expr & suffix)
            else:
              e.ln("return _check_ret((function()")
              e.indent += 1
              e.emitBody(bodyBlock, asReturn = true)
              e.indent -= 1
              e.ln("end)()" & suffix)
          else:
            e.emitBody(bodyBlock, asReturn = asRet)
          e.indent -= 1
          e.locals = savedLocals
          e.varTable = savedVarTable
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
        if isPureExpressionBody(trueBlock) and isPureExpressionBody(falseBlock):
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
        e.setVarSeqType(name, rhsSeqType)
      # Peek: if RHS is a context [...] literal, record the name so
      # loops over it iterate with pairs() instead of ipairs().
      if pos < vals.len and vals[pos].kind == vkWord and
         vals[pos].wordKind == wkWord and vals[pos].wordName == "context":
        e.contextVars.incl(name)
      # Peek ahead to infer if RHS is numeric — mark variable as concat-safe
      if isNumericExpr(vals, pos):
        e.markConcatSafe(name)
      elif pos < vals.len and vals[pos].kind == vkWord and
           vals[pos].wordKind == wkWord and "/" in vals[pos].wordName:
        let pathParts = vals[pos].wordName.split("/")
        if pathParts.len == 2:
          let vn = luaName(pathParts[0])
          let fn = luaName(pathParts[1])
          if e.isFieldSafeForConcat(vn, fn):
            e.markConcatSafe(name)
      elif pos < vals.len and vals[pos].kind == vkWord and
           vals[pos].wordKind == wkWord and
           vals[pos].wordName in e.funcReturnTypes and
           e.funcReturnTypes[vals[pos].wordName] in SafeConcatTypes:
        e.markConcatSafe(name)
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
        let base = exprHandlers[name](e, vals, pos).text
        let expr = e.emitMethodChain(base, vals, pos)
        if expr.len > 0 and expr != "nil":
          if expr.startsWith("("):
            e.ln(";" & expr)
          else:
            e.ln(expr)
        continue

    # --- Path call as statement (e.g., love/graphics/setColor 1.0 0.0 0.0) ---
    # Skip keywords that happen to contain a slash but aren't paths:
    # import/using is a dialect keyword handled by emitExpr.
    if val.kind == vkWord and val.wordKind == wkWord and val.wordName.contains('/') and
       val.wordName != "import/using":
      pos += 1
      let r = resolvePathCall(e, val.wordName, val.line, vals, pos)
      let final = if r.isFullCall: e.emitMethodChain(r.lua, vals, pos) else: r.lua
      e.ln(final)
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

## Prelude constants (runtime support helper source) live in
## prelude_consts.nim so this file stays focused on emission logic.

proc closeTypeUsageTransitively(e: var LuaEmitter) =
  ## Predicate bodies for composite @types reference other predicates by
  ## name. Walk the rules of every used type and pull in any custom-type
  ## reference, until fixpoint. Without this, a `union [a! | b!]` predicate
  ## emits `_b_p(it)` while `_b_p` is missing from the prelude.
  var changed = true
  while changed:
    changed = false
    var added: seq[string]
    for typeName in e.usedTypeChecks:
      if typeName notin e.customTypeRules: continue
      let rule = e.customTypeRules[typeName]
      let refs = case rule.kind
        of ctUnion: rule.unionTypes
        of ctWhere: rule.whereTypes
        of ctEnum: @[]
      for t in refs:
        let base = if t.endsWith("!"): t[0 ..< t.len - 1] else: t
        if base in e.customTypeRules and base notin e.usedTypeChecks:
          added.add(base)
    for n in added:
      e.usedTypeChecks.incl(n)
      changed = true

proc topoSortTypes(e: LuaEmitter, names: seq[string]): seq[string] =
  ## Order @type names so that dependencies come before dependents.
  ## A type referencing another in its rule must follow that other in
  ## the prelude. Ties broken by declaration order.
  var visited: HashSet[string]
  proc visit(name: string, acc: var seq[string]) =
    if name in visited: return
    visited.incl(name)
    if name notin e.customTypeRules: return
    let rule = e.customTypeRules[name]
    let refs = case rule.kind
      of ctUnion: rule.unionTypes
      of ctWhere: rule.whereTypes
      of ctEnum: @[]
    for t in refs:
      let base = if t.endsWith("!"): t[0 ..< t.len - 1] else: t
      if base in e.customTypeRules and base != name:
        visit(base, acc)
    acc.add(name)
  for n in names:
    visit(n, result)

proc expandStdlibIntoPrelude(e: var LuaEmitter): string

proc buildPrelude(e: var LuaEmitter): string =
  ## Build the runtime support prelude. Includes helper functions for any
  ## natives that need them, plus synthesized predicates for every @type
  ## declaration referenced in source by `is?` or match patterns.
  e.closeTypeUsageTransitively()
  var predTypeNames: seq[string]
  for typeName in e.customTypeRules.keys:
    if typeName in e.usedTypeChecks:
      predTypeNames.add(typeName)
  let ordered = e.topoSortTypes(predTypeNames)
  var typePreds: seq[string]
  for typeName in ordered:
    typePreds.add(e.emitCustomTypePredicateDecl(typeName))

  # Stdlib expansion is computed on demand — cheap since each usedStdlibSymbols
  # entry only spliceSelectedFunctions-es the requested subset.
  let stdlibLua = e.expandStdlibIntoPrelude()

  if e.usedHelpers.len == 0 and not e.usedRandom and not e.usedVariadicUnpack and
      typePreds.len == 0 and stdlibLua.len == 0:
    return ""
  var parts: seq[string] = @[
    "-- Kintsugi runtime support",
    "-- Reserved global names: _-prefixed helpers + stdlib fns. " &
      "Kintsugi user code must not shadow these.",
  ]
  if e.usedRandom:
    parts.add("math.randomseed(os.time())")
  if e.usedVariadicUnpack:
    parts.add(PreludeUnpack.strip)
  # Emit helper bodies demand-driven from the registry. Preserves the
  # declared emission order so dependencies (e.g. _equals before _has)
  # come first.
  for entry in PreludeRegistry:
    for flag in entry.useFlags:
      if flag in e.usedHelpers:
        parts.add(entry.body)
        break
  for tp in typePreds:
    parts.add(tp)
  if stdlibLua.len > 0:
    parts.add(stdlibLua.strip)
  parts.join("\n") & "\n\n"

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
          var bi = bindingFunc(spec.params.len, refInfos, retArity)
          for ps in spec.params:
            bi.paramTypes.add(ps.typeName)
            bi.paramNames.add(ps.name)
          e.bindings[name] = bi
          # Track return type for concat-safe inference in rejoin
          if spec.returnType.len > 0:
            e.funcReturnTypes[name] = spec.returnType
          else:
            # Heuristic: a single-expression body that is pure arithmetic
            # on params/numeric-literals returns a number. Lua's `+ - * /`
            # only accept numbers, so the return type is numeric regardless
            # of whether the params are type-annotated.
            if i + 3 < vals.len and vals[i + 3].kind == vkBlock:
              let body = vals[i + 3].blockVals
              var paramNames: HashSet[string]
              for ps in spec.params: paramNames.incl(ps.name)
              var pureArith = body.len > 0
              var hasArithOp = false
              for v in body:
                case v.kind
                of vkInteger, vkFloat: discard
                of vkOp:
                  if v.opSymbol in ["+", "-", "*", "/"]: hasArithOp = true
                  else: pureArith = false
                of vkWord:
                  if v.wordKind == wkWord and v.wordName in paramNames: discard
                  elif v.wordKind == wkWord and v.wordName in ["+", "-", "*", "/"]:
                    hasArithOp = true
                  else: pureArith = false
                else: pureArith = false
                if not pureArith: break
              if pureArith and hasArithOp:
                e.funcReturnTypes[name] = "integer!"
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
          var fields: seq[tuple[name: string, default: string,
                                 fieldType: string, arity: int]] = @[]
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
                            fields.add((name: fieldName, default: defaultVal, fieldType: fType, arity: -1))
                          else:
                            fields.add((name: fieldName, default: "nil", fieldType: fType, arity: -1))
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
                    fields.add((name: fieldName, default: defaultVal, fieldType: fType, arity: -1))
                  else:
                    fields.add((name: fieldName, default: "nil", fieldType: fType, arity: -1))
                si += 2
                continue
            # set-word: method or computed field. Extract method arity from
            # `function [spec] [body]` / `does [body]` so `->` can consume
            # the correct number of args.
            if specBlock[si].kind == vkWord and specBlock[si].wordKind == wkSetWord:
              let fieldName = luaName(specBlock[si].wordName)
              si += 1
              var fArity = -1
              if si < specBlock.len and specBlock[si].kind == vkWord and
                 specBlock[si].wordKind == wkWord:
                if specBlock[si].wordName == "function" and
                   si + 1 < specBlock.len and specBlock[si + 1].kind == vkBlock:
                  let spec = parseFuncSpec(specBlock[si + 1].blockVals)
                  fArity = spec.params.len
                elif specBlock[si].wordName == "does":
                  fArity = 0
              var fpos = si
              let value = e.emitExpr(specBlock, fpos)
              si = fpos
              fields.add((name: fieldName, default: value, fieldType: "", arity: fArity))
              continue
            si += 1
          e.objectFields[kebabName] = fields
          i += 3
        else:
          i += 2
        continue
      # name: @type/guard [params] [body] — register fn binding + mark
      # name as @type/guard-eligible. Body is captured for late validation
      # (after all prescan completes, so mutually-recursive guards work).
      elif i + 1 < vals.len and vals[i + 1].kind == vkWord and
           vals[i + 1].wordKind == wkMetaWord and
           vals[i + 1].wordName == "type/guard":
        if i + 3 < vals.len and vals[i + 2].kind == vkBlock and
           vals[i + 3].kind == vkBlock:
          let spec = parseFuncSpec(vals[i + 2].blockVals)
          var refInfos: seq[RefinementInfo] = @[]
          for r in spec.refinements:
            refInfos.add(RefinementInfo(name: r.name, paramCount: r.params.len))
          var bi = bindingFunc(spec.params.len, refInfos, -1)
          for ps in spec.params:
            bi.paramTypes.add(ps.typeName)
            bi.paramNames.add(ps.name)
          e.bindings[name] = bi
          e.guardFuncs.incl(name)
          var paramNames: HashSet[string]
          for p in spec.params: paramNames.incl(p.name)
          e.guardFuncBodies[name] = (
            body: vals[i + 3].blockVals,
            paramNames: paramNames,
            line: vals[i + 1].line
          )
          e.prescanBlock(vals[i + 3].blockVals)
          i += 4
          continue
      # name!: @type / @type/where / @type/enum — record rule, skip emission
      elif i + 1 < vals.len and vals[i + 1].kind == vkWord and
           vals[i + 1].wordKind == wkMetaWord and
           (vals[i + 1].wordName == "type" or vals[i + 1].wordName.startsWith("type/")):
        let metaName = vals[i + 1].wordName
        let baseName = if name.endsWith("!"): name[0 ..< name.len - 1] else: name
        e.bindings[name] = bindingVal()  # erase emission; value not referenced
        if i + 2 < vals.len and vals[i + 2].kind == vkBlock:
          let ruleBlk = vals[i + 2].blockVals
          if metaName == "type/enum":
            var members: seq[string]
            for rv in ruleBlk:
              if rv.kind == vkWord and rv.wordKind == wkLitWord:
                members.add(rv.wordName)
            e.customTypeRules[baseName] =
              CustomTypeRule(kind: ctEnum, enumMembers: members)
            i += 3
            continue
          if metaName == "type/where" and i + 3 < vals.len and
             vals[i + 3].kind == vkBlock:
            var bases: seq[string]
            for rv in ruleBlk:
              if rv.kind == vkType: bases.add(rv.typeName)
            e.customTypeRules[baseName] =
              CustomTypeRule(kind: ctWhere, whereTypes: bases,
                             guardBody: vals[i + 3].blockVals)
            i += 4
            continue
          # Plain @type: union of built-in or custom type names
          var bases: seq[string]
          for rv in ruleBlk:
            if rv.kind == vkType: bases.add(rv.typeName)
          e.customTypeRules[baseName] =
            CustomTypeRule(kind: ctUnion, unionTypes: bases)
          i += 3
          continue
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
          e.setVarType(name, typeName)
        e.bindings[name] = bindingVal()
      # name: attempt [...] with no `source` block — reusable 1-arg fn of `it`.
      # Matches src/dialects/attempt_dialect.nim which returns a KtgNative
      # of arity 1. Prescan arity so call sites consume 1 arg.
      elif i + 1 < vals.len and vals[i + 1].kind == vkWord and
           vals[i + 1].wordKind == wkWord and vals[i + 1].wordName == "attempt":
        var isSourceless = true
        if i + 2 < vals.len and vals[i + 2].kind == vkBlock:
          for v in vals[i + 2].blockVals:
            if v.kind == vkWord and v.wordKind == wkWord and
               v.wordName == "source":
              isSourceless = false
              break
        e.bindings[name] =
          if isSourceless: bindingFunc(1)
          else: bindingVal()
      else:
        # name: <non-function> — it's a value (overrides native if same name)
        e.bindings[name] = bindingVal()
    i += 1

proc inferReturnArities(e: var LuaEmitter, vals: seq[KtgValue]) =
  ## Second-pass return-arity propagation. Runs after prescanBlock has
  ## populated all user bindings, so forward references resolve. For a
  ## set-word `name: calledName args`, if calledName has a known return
  ## arity, mark `name` as callable with that arity. Also handles
  ## `name: does [... function [spec] [body]]`, where a zero-arg factory
  ## returns an inner callable.
  ##
  ## Called automatically by prescanBlock on the top-level walk.
  var i = 0
  while i < vals.len:
    if vals[i].kind == vkWord and vals[i].wordKind == wkSetWord:
      let name = vals[i].wordName
      if i + 1 < vals.len and vals[i + 1].kind == vkWord and
         vals[i + 1].wordKind == wkWord:
        let calledName = vals[i + 1].wordName
        let info = e.getBinding(calledName)
        if info.isFunction and info.returnArity >= 0:
          e.bindings[name] = bindingFunc(info.returnArity)
        elif calledName == "does" and i + 2 < vals.len and
             vals[i + 2].kind == vkBlock:
          let body = vals[i + 2].blockVals
          if body.len >= 3 and
             body[^3].kind == vkWord and body[^3].wordKind == wkWord and
             body[^3].wordName == "function" and
             body[^2].kind == vkBlock and body[^1].kind == vkBlock:
            let innerSpec = parseFuncSpec(body[^2].blockVals)
            e.bindings[name] = bindingFunc(0, retArity = innerSpec.params.len)
      # Recurse into function bodies for nested set-words
      if i + 1 < vals.len and vals[i + 1].kind == vkWord and
         vals[i + 1].wordKind == wkWord and vals[i + 1].wordName == "function" and
         i + 3 < vals.len and vals[i + 3].kind == vkBlock:
        e.inferReturnArities(vals[i + 3].blockVals)
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

proc collectModuleNames(vals: seq[KtgValue]): HashSet[string] =
  ## Walk the top-level values linearly and pick up every set-word.
  ## Does NOT recurse into blocks, so set-words inside function bodies,
  ## object specs, `if` bodies, etc. are not included — only names that
  ## are defined at module scope end up in the set.
  result = initHashSet[string]()
  for v in vals:
    if v.kind == vkWord and v.wordKind == wkSetWord and not v.wordName.contains('/'):
      result.incl(luaName(v.wordName))

proc validatePass(e: var LuaEmitter, vals: seq[KtgValue])

proc emitLuaModuleEx(ast: seq[KtgValue], sourceDir: string,
                     compiling: HashSet[string],
                     eval: Evaluator = nil,
                     target: string = ""):
    tuple[lua: string, e: LuaEmitter] =
  ## Compile a Kintsugi module to Lua and return both the source and the
  ## inner LuaEmitter, so a parent (entrypoint) compile can merge the
  ## module's used helper / type-predicate / stdlib-symbol sets into its
  ## own prelude. Modules emit no prelude themselves; helpers come from
  ## the entrypoint's prelude.lua at runtime.
  var e = LuaEmitter(
    indent: 0,
    output: "",
    bindings: initNativeBindings(),
    nameMap: initTable[string, string](),
    bindingKinds: initTable[string, BindingKind](),
    sourceDir: sourceDir,
    compiling: compiling,
    moduleNames: collectModuleNames(ast),
    eval: eval,
    target: target
  )
  e.prescanBlock(ast)
  e.inferReturnArities(ast)
  e.validateAllGuards()
  e.validatePass(ast)
  
  
  e.emitBlock(ast)
  let exports = findExports(ast)
  if exports.len > 0:
    var parts: seq[string] = @[]
    for name in exports:
      let lua = luaName(name)
      parts.add(lua & " = " & lua)
    e.ln("return {" & parts.join(", ") & "}")
  (lua: e.output, e: e)

proc emitLuaModule*(ast: seq[KtgValue], sourceDir: string = "",
                    compiling: HashSet[string] = initHashSet[string](),
                    eval: Evaluator = nil,
                    target: string = ""):
    tuple[lua: string, depWrites: seq[tuple[path: string, lua: string]]] =
  ## Compile a module. Returns the compiled Lua and any deferred dep-file
  ## writes produced by nested `import %path` directives. Callers write
  ## those to disk themselves; the emitter never touches the filesystem.
  let (lua, e) = emitLuaModuleEx(ast, sourceDir, compiling, eval, target)
  (lua: lua, depWrites: e.pendingDepWrites)

proc isLiteralArg(v: KtgValue): bool =
  ## A standalone value that compile-time guard evaluation can trust.
  ## Excludes computed expressions (paren-wrapped, infix chains, calls).
  v.kind in {vkInteger, vkFloat, vkString, vkLogic, vkNone, vkMoney,
             vkPair, vkTuple, vkDate, vkTime, vkFile, vkUrl, vkEmail} or
    (v.kind == vkWord and v.wordKind == wkLitWord)

proc matchesCustomRule(e: LuaEmitter, rule: CustomTypeRule, arg: KtgValue): bool =
  ## Check if `arg` satisfies `rule`. Union / enum rules are structural —
  ## no evaluator needed. Where rules run the guard body via e.eval; when
  ## e.eval is nil the rule is assumed to pass (caller falls through to
  ## the runtime prologue for verification).
  case rule.kind
  of ctUnion:
    let actual = typeName(arg)
    for t in rule.unionTypes:
      if actual == t: return true
      let base = customTypeBase(t)
      if base in e.customTypeRules:
        if e.matchesCustomRule(e.customTypeRules[base], arg):
          return true
    false
  of ctEnum:
    if arg.kind == vkWord and arg.wordKind == wkLitWord:
      return arg.wordName in rule.enumMembers
    false
  of ctWhere:
    # Base-type gate: the arg's kind must satisfy one of the whereTypes
    # before we run the guard body.
    let actual = typeName(arg)
    var baseMatch = rule.whereTypes.len == 0
    for t in rule.whereTypes:
      if actual == t:
        baseMatch = true
      else:
        let base = customTypeBase(t)
        if base in e.customTypeRules and
           e.matchesCustomRule(e.customTypeRules[base], arg):
          baseMatch = true
    if not baseMatch: return false
    if e.eval == nil: return true
    let ctx = e.eval.global.child
    ctx.set("it", arg)
    try:
      let r = e.eval.evalBlock(rule.guardBody, ctx)
      r.kind == vkLogic and r.boolVal
    except CatchableError:
      true

proc validatePass(e: var LuaEmitter, vals: seq[KtgValue]) =
  ## Single AST walk that performs all pre-emission validations and scans:
  ##
  ## 1. `is?` usage -> populate `usedTypeChecks` (drives `_type` tagging
  ##    in `make` output).
  ## 2. `none?` usage -> set `programUsesNoneCheck` (drives `_NONE`
  ##    sentinel emission for block literals).
  ## 3. Literal args to functions with custom-typed params -> run the
  ##    type's guard at compile time and raise EmitError on provable
  ##    violations. Runtime-prologue guards catch the rest.
  ##
  ## Previously three separate passes (scanTypeChecks + scanNoneUsage +
  ## validateLiteralTypeChecks). Merged so each emission now touches the
  ## AST three fewer times and keeping these behaviors in sync is a
  ## single-file edit.
  for i in 0 ..< vals.len:
    # Recurse into blocks/parens first so nested constructs are covered.
    case vals[i].kind
    of vkBlock: e.validatePass(vals[i].blockVals)
    of vkParen: e.validatePass(vals[i].parenVals)
    else: discard

    if vals[i].kind != vkWord or vals[i].wordKind != wkWord: continue
    let name = vals[i].wordName

    # --- 1. is? <type!> ---
    if name == "is?" and i + 1 < vals.len and vals[i + 1].kind == vkType:
      var raw = vals[i + 1].typeName.toLower
      if raw.endsWith("!"):
        raw = raw[0 ..< raw.len - 1]
      e.usedTypeChecks.incl(raw.replace("_", "-"))

    # --- 2. none? usage ---
    if name == "none?":
      e.programUsesNoneCheck = true

    # --- 3. Literal-arg type guard ---
    if name notin e.bindings: continue
    let bi = e.bindings[name]
    if not bi.isFunction: continue
    if bi.paramTypes.len == 0: continue

    for j in 0 ..< bi.paramTypes.len:
      let paramType = bi.paramTypes[j]
      if paramType.len == 0: continue
      let base = customTypeBase(paramType)
      if base notin e.customTypeRules: continue

      let argIdx = i + 1 + j
      if argIdx >= vals.len: break
      let arg = vals[argIdx]
      if not isLiteralArg(arg): continue
      # If an infix op follows the arg, the real arg is a computed
      # expression — we can't verify it literally.
      if argIdx + 1 < vals.len and isInfixOp(vals[argIdx + 1]): continue

      let passes = e.matchesCustomRule(e.customTypeRules[base], arg)
      if not passes:
        let actual = typeName(arg)
        raise EmitError(msg:
          bi.paramNames[j] & " expects " & paramType & ", got " & actual &
          " (" & $arg & " fails " & paramType & " guard at compile time)")

proc expandStdlibIntoPrelude(e: var LuaEmitter): string =
  ## For each module recorded in usedStdlibSymbols, splice its requested
  ## fns and emit them via a fresh sub-emitter. Strip the `local` keyword
  ## off function declarations so the stdlib lives as globals in the
  ## prelude alongside the other helpers.
  result = ""
  template lua: untyped = result
  for moduleName, syms in e.usedStdlibSymbols:
    var symList: seq[string]
    if "*" in syms:
      symList = moduleExports(moduleName)
    else:
      for s in syms: symList.add(s)
    let fnsAst = spliceSelectedFunctions(moduleName, symList)
    if fnsAst.len == 0: continue
    var sub = LuaEmitter(
      indent: 0, output: "",
      bindings: initNativeBindings(),
      nameMap: initTable[string, string](),
      bindingKinds: initTable[string, BindingKind](),
      sourceDir: e.sourceDir,
      moduleNames: collectModuleNames(fnsAst)
    )
    sub.prescanBlock(fnsAst)
    sub.inferReturnArities(fnsAst)
    sub.emitBlock(fnsAst)
    var fnLua = sub.output
    fnLua = fnLua.replace("\nlocal function ", "\nfunction ")
    if fnLua.startsWith("local function "):
      fnLua = fnLua["local ".len .. ^1]
    lua &= fnLua

proc emitLuaSplit*(ast: seq[KtgValue], sourceDir: string = "",
                   target: string = "",
                   eval: Evaluator = nil):
    tuple[prelude, source: string,
          depWrites: seq[tuple[path: string, lua: string]]] =
  ## Compile a Kintsugi entrypoint into the runtime-support prelude, the
  ## source body, and a list of dependency .lua files produced by nested
  ## `import %path` directives. Caller is responsible for writing all
  ## three to disk; the emitter itself never touches the filesystem.
  ##
  ## When `eval` is non-nil, compile-time guard checks run on literal
  ## args against custom-typed params — failing guards raise EmitError.
  ## Non-literal args fall through to the runtime prologue emitted at
  ## the top of each typed function.
  var e = LuaEmitter(
    indent: 0,
    output: "",
    bindings: initNativeBindings(),
    nameMap: initTable[string, string](),
    bindingKinds: initTable[string, BindingKind](),
    sourceDir: sourceDir,
    moduleNames: collectModuleNames(ast),
    eval: eval,
    target: target
  )
  e.prescanBlock(ast)
  e.inferReturnArities(ast)
  e.validateAllGuards()
  e.validatePass(ast)
  
  
  e.emitBlock(ast)
  let prelude = e.buildPrelude()
  var source = e.output
  # If there's any prelude content, the source needs to load it. Pick the
  # right include syntax for the target.
  if prelude.len > 0:
    let includeLine =
      if target == "playdate": "import 'prelude'\n"
      else: "require('prelude')\n"
    source = includeLine & source
  (prelude: prelude, source: source, depWrites: e.pendingDepWrites)

## The `emitLua` single-string wrapper that used to live here has been
## moved to `tests/emit_test_helper.nim` — it's a test-only convenience,
## not a production API. Production callers (CLI, playground) use
## `emitLuaSplit` and `emitLuaModule` directly.
