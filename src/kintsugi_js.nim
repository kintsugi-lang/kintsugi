## JS entry point for Kintsugi - exposes compile() and run() to the browser.
##
## Build: nim js -d:release --outdir:web src/kintsugi_js.nim
##
## This entry skips the CLI, REPL, and disk-based module loading. Single-source
## compile and interpret only - enough for a playground / try-me app.
## `import %path` raises a compile error on this backend.
##
## Stdlib is available via `import 'math` / `import/using 'math [clamp]`.

import std/json
import core/[types, version]
import parse/parser
import eval/[dialect, evaluator, natives]
import emit/lua
import dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]

proc setupEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerObjectDialect()
  eval.registerAttempt()
  eval.registerParse()
  eval

proc kintsugiCompile*(source: cstring, target: cstring): cstring {.exportc.} =
  ## Returns a JSON string `{"prelude": "...", "source": "...", "error": ...}`.
  ## Playground destructures into separate panes. On error, both prelude
  ## and source are empty and `error` carries the message; otherwise
  ## `error` is null.
  try:
    let ast = parseSource($source)
    let eval = setupEval()
    let processed = eval.preprocess(ast, forCompilation = true, target = $target)
    let (prelude, body) = emitLuaSplit(processed, "", $target, eval)
    cstring($(%*{"prelude": prelude, "source": body, "error": newJNull()}))
  except KtgError as e:
    cstring($(%*{"prelude": "", "source": "",
                 "error": "[" & e.kind & "]: " & e.msg}))
  except CatchableError as e:
    cstring($(%*{"prelude": "", "source": "", "error": e.msg}))

proc kintsugiRun*(source: cstring): cstring {.exportc.} =
  try:
    let eval = setupEval()
    discard eval.evalString($source)
    var combinedOut = ""
    for line in eval.output:
      combinedOut &= line & "\n"
    cstring(combinedOut)
  except KtgError as e:
    cstring("Error [" & e.kind & "]: " & e.msg)
  except CatchableError as e:
    cstring("Error: " & e.msg)

proc kintsugiVersion*(): cstring {.exportc.} =
  cstring(VERSION)

proc kintsugiCodename*(): cstring {.exportc.} =
  cstring(CODENAME)

proc kintsugiBuildDate*(): cstring {.exportc.} =
  cstring(BUILD_DATE)
