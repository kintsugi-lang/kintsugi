## Global name allowlists for the strict-globals diagnostic.
##
## Kintsugi user code emits as Lua globals when a name isn't declared locally,
## isn't in the bindings dialect map, and isn't a prescanned user binding.
## The emitter rejects such names by default; this module holds the sets of
## names that ARE allowed (Lua stdlib, Kintsugi reserved-word escapes, and
## target-specific globals for LOVE2D / Playdate).

import std/sets

## Lua reserved words. If a Kintsugi identifier sanitizes to one, the emitter
## prefixes with `_k_` so the output is a legal Lua identifier.
const LuaReserved* = [
  "and", "break", "do", "else", "elseif", "end", "false", "for",
  "function", "goto", "if", "in", "local", "nil", "not", "or",
  "repeat", "return", "then", "true", "until", "while"
].toHashSet

## Lua standard globals that Kintsugi user code can reference without an
## explicit binding or local declaration. Anything not in this set (or in
## bindings/locals/moduleNames/nameMap/target allowlist) is a typo or a
## missing `bindings [...]` entry; the strict-globals pass rejects it.
const LuaStdlibGlobals* = [
  "math", "string", "table", "io", "os", "coroutine", "debug", "package",
  "print", "tostring", "tonumber", "pairs", "ipairs", "type", "error",
  "pcall", "xpcall", "assert", "require", "unpack", "setmetatable",
  "getmetatable", "select", "next", "rawget", "rawset", "rawequal",
  "rawlen", "collectgarbage", "dofile", "loadfile", "loadstring", "load",
  "_G", "_ENV", "_VERSION"
].toHashSet

## Target-specific globals merged into the allowlist when the matching
## --target flag is active.
const Love2dGlobals* = ["love"].toHashSet
const PlaydateGlobals* = ["playdate", "import", "json", "graphics"].toHashSet
