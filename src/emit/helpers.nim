## Pure helper procs used by the Lua emitter.
##
## Everything here is either a pure function or reads immutable AST — no
## proc takes `var LuaEmitter`. Extracted from lua.nim so the emission
## logic there can focus on emitter state manipulation, while these
## small string/AST utilities stand alone for easy review and testing.

import std/[strutils, sets]
import ../core/types
import ./globals

# ---------------------------------------------------------------------------
# Identifier sanitization
# ---------------------------------------------------------------------------

proc sanitize*(name: string): string =
  ## Convert Kintsugi identifiers to valid Lua identifiers.
  ## foo? -> is_foo, foo! -> foo_bang, foo-bar -> foo_bar
  result = name
  if result.endsWith("?"):
    result = "is_" & result[0..^2]
  if result.endsWith("!"):
    result = result[0..^2] & "_bang"
  result = result.replace("-", "_")
  # Path slashes are handled separately in emitPath.

proc luaEscape*(s: string): string =
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

proc luaName*(name: string): string =
  let s = sanitize(name)
  if s in LuaReserved:
    "_k_" & s
  else:
    s

proc emitPath*(name: string): string =
  let parts = name.split('/')
  result = luaName(parts[0])
  for i in 1 ..< parts.len:
    if parts[i].startsWith(":"):
      # Dynamic get-word segment: /:var -> [var]
      result &= "[" & luaName(parts[i][1..^1]) & "]"
    else:
      result &= "." & luaName(parts[i])

# ---------------------------------------------------------------------------
# Infix operator helpers
# ---------------------------------------------------------------------------

proc isInfixOp*(val: KtgValue): bool =
  val.kind == vkOp or
    (val.kind == vkWord and val.wordKind == wkWord and
     val.wordName in ["and", "or"])

proc luaOp*(op: string): string =
  case op
  of "=", "==": "=="
  of "<>": "~="
  of "%": "%"
  of "and": "and"
  of "or": "or"
  else: op  # +, -, *, /, <, >, <=, >= are the same

proc luaPrec*(op: string): int =
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
# Paren / wrap helpers (string-level — will be replaced by LuaExpr in Phase 3c)
# ---------------------------------------------------------------------------

proc needsParens*(expr: string): bool =
  ## An expression needs wrapping when `and`/`or` (lowest precedence) is
  ## visible in its text and it's about to be composed by a higher-
  ## precedence operator.
  " and " in expr or " or " in expr

proc parenIfComposed*(expr: string): string =
  ## Paren-wrap when the expression contains `and`/`or`. Callers use this
  ## only when downstream composition (==, ~=, concat) could mis-group.
  if needsParens(expr): "(" & expr & ")" else: expr

proc wrapIfTableCtor*(expr: string): string =
  ## Wrap table constructors so they can be indexed: ({...})[n].
  if expr.len > 0 and expr[0] == '{': "(" & expr & ")"
  else: expr

# ---------------------------------------------------------------------------
# Type-check emission (primitive + custom-type name helpers)
# ---------------------------------------------------------------------------

proc isPureExpressionBody*(vals: seq[KtgValue]): bool =
  ## True when `vals` is structurally a single pure expression with no
  ## statement-level effects or control flow. Emitters use this to decide
  ## between inlining (direct value) vs IIFE-wrapping (statement block
  ## that captures a return value).
  ##
  ## Replaces the older `vals.len <= 3` heuristic, which wrongly matched
  ## three-statement bodies like `[a b c]` (three bare references) and
  ## mis-classified `[x: 1 y]` (set-word followed by bare reference).
  ##
  ## Conservative: on ambiguity, returns false so the IIFE fallback is
  ## used. False negatives produce slightly verbose Lua; false positives
  ## would produce wrong Lua. We prefer the former.
  if vals.len == 0: return false
  # Reject any statement-like token: set-word, control-flow keyword,
  # statement-only native, or meta-word.
  for v in vals:
    if v.kind == vkWord:
      case v.wordKind
      of wkSetWord, wkMetaWord: return false
      of wkWord:
        if v.wordName in [
            "if", "either", "unless", "loop", "match", "scope",
            "return", "break", "error", "print", "probe", "assert",
            "set", "remove", "insert", "append", "raw",
            "try", "attempt", "function", "does", "object", "context",
            "capture"]:
          return false
      else: discard
  # Common shapes that are clearly one expression:
  #   len == 1                     — bare literal, word, block, paren
  #   len == 3 with infix op       — `a OP b`
  #   len == 2, head is a word     — one-arg call: `negate x`
  #   len == 3, head is a word     — two-arg call: `min a b` (and the
  #     mid-token isn't an infix op, which case 2 handles). The only
  #     shape this mis-classifies is `[value value value]` (three bare
  #     references as three statements), which is rare and produces
  #     verbose-but-correct Lua when it happens.
  if vals.len == 1: return true
  if vals.len == 2 and vals[0].kind == vkWord and
     vals[0].wordKind == wkWord: return true
  if vals.len == 3 and isInfixOp(vals[1]): return true
  if vals.len == 3 and vals[0].kind == vkWord and
     vals[0].wordKind == wkWord and not isInfixOp(vals[1]): return true
  # Longer chains (a + b + c, nested calls) are conservatively rejected.
  false

proc ktgTypeToLuaType*(typeName: string): string =
  ## Map a Kintsugi type! to the Lua `type(x)` result string that detects
  ## it. Returns the quoted Lua type name. For unrecognized custom types
  ## (e.g. `money!`, `enemy!`), returns the literal type name as a string
  ## so callers get `type(x) == "money!"` — which always evaluates false
  ## and surfaces as a clear pattern miss rather than a silent any-table.
  case typeName
  of "integer!", "float!", "number!": "\"number\""
  of "string!": "\"string\""
  of "logic!": "\"boolean\""
  of "none!": "\"nil\""
  of "block!", "context!", "map!", "object!": "\"table\""
  of "function!", "native!": "\"function\""
  else: "\"" & typeName & "\""

proc inlineTypePredicate*(name, valueExpr: string): string =
  ## Inline emission for built-in type predicates in match patterns.
  case name
  of "integer?":
    "type(" & valueExpr & ") == \"number\" and math.floor(" &
      valueExpr & ") == " & valueExpr
  of "float?", "number?": "type(" & valueExpr & ") == \"number\""
  of "string?":           "type(" & valueExpr & ") == \"string\""
  of "logic?":            "type(" & valueExpr & ") == \"boolean\""
  of "none?":             valueExpr & " == nil"
  of "block?":            "type(" & valueExpr & ") == \"table\""
  else: ""  # unreachable — caller gates on BuiltinTypePredicates

proc primitiveTypeCheck*(typeName, valExpr: string): string =
  ## Lua expression testing a primitive type against valExpr. Unparenthesized —
  ## the caller adds grouping when the surrounding precedence needs it.
  ## Returns empty string when typeName is not a recognized primitive.
  case typeName
  of "integer": "type(" & valExpr & ") == \"number\" and math.floor(" & valExpr & ") == " & valExpr
  of "float": "type(" & valExpr & ") == \"number\" and math.floor(" & valExpr & ") ~= " & valExpr
  of "number": "type(" & valExpr & ") == \"number\""
  of "string": "type(" & valExpr & ") == \"string\""
  of "logic": "type(" & valExpr & ") == \"boolean\""
  of "function", "native": "type(" & valExpr & ") == \"function\""
  of "block", "context", "map", "object": "type(" & valExpr & ") == \"table\""
  of "none": valExpr & " == nil"
  else: ""

proc customTypePredicateName*(typeName: string): string =
  ## Lua name for a synthesized custom-type predicate.
  "_" & typeName.replace("-", "_") & "_p"

proc customTypeBase*(typeName: string): string =
  ## Strip trailing `!` and normalize to kebab-case for customTypeRules lookup.
  var t = typeName.toLower
  if t.endsWith("!"):
    t = t[0 ..< t.len - 1]
  t.replace("_", "-")
