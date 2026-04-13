## JS entry point for Kintsugi - exposes compile() and run() to the browser.
##
## Build: nim js -d:release --outdir:web src/kintsugi_js.nim
##
## This entry skips the CLI, REPL, and disk-based module loading. Single-source
## compile and interpret only - enough for a playground / try-me app.
## `import %path` raises a compile error on this backend.
##
## Stdlib (`lib/math.ktg`, `lib/collections.ktg`) is embedded via `staticRead`
## at Nim compile time and prepended to user source for both compile and run,
## so functions like `clamp`, `lerp`, `range`, `flatten` are available without
## any `import` or `using` header.

import std/strutils
import core/types
import parse/parser
import eval/[dialect, evaluator, natives]
import emit/lua
import dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]

proc stripHeader(source: string): string =
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

# Embedded stdlib, headers stripped at compile time.
const
  mathSrc = stripHeader(staticRead("../lib/math.ktg"))
  collectionsSrc = stripHeader(staticRead("../lib/collections.ktg"))
  stdlibPrelude = mathSrc & "\n" & collectionsSrc & "\n"

proc withStdlib(userSource: string): string =
  stdlibPrelude & stripHeader(userSource)

proc setupEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerObjectDialect()
  eval.registerAttempt()
  eval.registerParse()
  eval

proc kintsugiCompile*(source: cstring): cstring {.exportc.} =
  try:
    let combined = withStdlib($source)
    let ast = parseSource(combined)
    let eval = setupEval()
    let processed = eval.preprocess(ast, forCompilation = true)
    cstring(emitLua(processed, ""))
  except KtgError as e:
    cstring("-- Error [" & e.kind & "]: " & e.msg)
  except CatchableError as e:
    cstring("-- Error: " & e.msg)

proc kintsugiRun*(source: cstring): cstring {.exportc.} =
  try:
    let combined = withStdlib($source)
    let eval = setupEval()
    discard eval.evalString(combined)
    var combinedOut = ""
    for line in eval.output:
      combinedOut &= line & "\n"
    cstring(combinedOut)
  except KtgError as e:
    cstring("Error [" & e.kind & "]: " & e.msg)
  except CatchableError as e:
    cstring("Error: " & e.msg)

proc kintsugiVersion*(): cstring {.exportc.} =
  cstring("0.4.0")
