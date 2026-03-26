## Kintsugi programming language — CLI entry point.
##
## Usage:
##   kintsugi                  — start REPL
##   kintsugi <file>           — run a file
##   kintsugi -c <file>        — compile to Lua (stdout)
##   kintsugi --compile <file> — compile to Lua (stdout)

import std/[os, strutils]
import core/types
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

proc repl() =
  let eval = setupEval()
  echo "Kintsugi v0.1.0"
  echo "Type expressions to evaluate. Ctrl+D to exit."
  echo ""

  while true:
    stdout.write(">> ")
    stdout.flushFile()

    var line: string
    try:
      if not stdin.readLine(line):
        echo ""
        break
    except EOFError:
      echo ""
      break

    if line.strip.len == 0:
      continue

    try:
      let result = eval.evalString(line)
      if result.kind != vkNone:
        echo $result
    except KtgError as e:
      echo "Error [" & e.kind & "]: " & e.msg
    except CatchableError as e:
      echo "Error: " & e.msg

proc runFile(path: string) =
  if not fileExists(path):
    echo "Error: file not found: " & path
    quit(1)

  let source = readFile(path)
  let eval = setupEval()

  try:
    discard eval.evalString(source)
  except KtgError as e:
    echo "Error [" & e.kind & "]: " & e.msg
    if e.stack.len > 0:
      echo "Stack trace:"
      for frame in e.stack:
        echo "  " & frame.name & " at line " & $frame.line
    quit(1)
  except CatchableError as e:
    echo "Error: " & e.msg
    quit(1)

proc compileLua(path: string) =
  if not fileExists(path):
    echo "Error: file not found: " & path
    quit(1)

  let source = readFile(path)
  let ast = parseSource(source)
  let luaCode = emitLua(ast)
  echo luaCode

proc main() =
  let args = commandLineParams()

  if args.len == 0:
    repl()
    return

  # Check for compile flag
  if args.len >= 2 and (args[0] == "-c" or args[0] == "--compile"):
    compileLua(args[1])
    return

  if args.len == 1:
    let path = args[0]

    if not fileExists(path):
      echo "Error: file not found: " & path
      quit(1)

    let source = readFile(path)

    # Check for Kintsugi/Lua header
    if source.startsWith("Kintsugi/Lua"):
      compileLua(path)
    else:
      runFile(path)
    return

  echo "Usage: kintsugi [options] [file]"
  echo "  (no args)          Start REPL"
  echo "  <file>             Run a Kintsugi file"
  echo "  -c, --compile <file>  Compile to Lua"
  quit(1)

main()
