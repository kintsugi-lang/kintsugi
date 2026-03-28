## Kintsugi programming language — CLI entry point.
##
## Usage:
##   kintsugi                  — start REPL
##   kintsugi <file>           — run a file
##   kintsugi -e <expr>        — evaluate expression
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
  echo "======== Kintsugi v0.3.0 ========"
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

proc stripHeader(source: string): string =
  ## Strip Kintsugi [...] header if present.
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

proc runFile(path: string) =
  if not fileExists(path):
    echo "Error: file not found: " & path
    quit(1)

  let source = stripHeader(readFile(path))
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

proc compileLua(path: string, outPath: string = "") =
  if not fileExists(path):
    echo "Error: file not found: " & path
    quit(1)

  let source = stripHeader(readFile(path))
  let ast = parseSource(source)
  let eval = setupEval()
  let processed = eval.preprocess(ast)
  let sourceDir = parentDir(absolutePath(path))
  let luaCode = emitLua(processed, sourceDir)

  if outPath.len > 0:
    writeFile(outPath, luaCode)
    echo "Compiled: " & path & " -> " & outPath
  else:
    # Default: same name with .lua extension
    let defaultOut = path.changeFileExt("lua")
    writeFile(defaultOut, luaCode)
    echo "Compiled: " & path & " -> " & defaultOut

proc main() =
  let args = commandLineParams()

  if args.len == 0:
    repl()
    return

  var i = 0
  var compile = false
  var evalExpr = ""
  var outPath = ""
  var filePath = ""

  while i < args.len:
    case args[i]
    of "-e", "--eval":
      if i + 1 < args.len:
        i += 1
        evalExpr = args[i]
      else:
        echo "Error: -e requires an expression"
        quit(1)
    of "-c", "--compile":
      compile = true
    of "-o", "--output":
      if i + 1 < args.len:
        i += 1
        outPath = args[i]
      else:
        echo "Error: -o requires a path"
        quit(1)
    of "--stdout":
      outPath = "-"
    else:
      filePath = args[i]
    i += 1

  if evalExpr.len > 0:
    let eval = setupEval()
    try:
      let result = eval.evalString(evalExpr)
      if result.kind != vkNone:
        echo $result
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
    return

  if filePath.len == 0 and not compile:
    echo "Usage: kintsugi [options] [file]"
    echo ""
    echo "  (no args)                    Start REPL"
    echo "  <file>                       Run a Kintsugi file"
    echo "  -e, --eval <expr>            Evaluate expression"
    echo "  -c, --compile <file>         Compile to Lua (.ktg -> .lua)"
    echo "  -c <file> -o <out>           Compile to specific output file"
    echo "  -c <file> --stdout           Compile to stdout"
    quit(1)

  if compile:
    if outPath == "-":
      # stdout mode
      let source = stripHeader(readFile(filePath))
      let ast = parseSource(source)
      let eval = setupEval()
      let processed = eval.preprocess(ast)
      let sourceDir = parentDir(absolutePath(filePath))
      echo emitLua(processed, sourceDir)
    else:
      compileLua(filePath, outPath)
    return

  # Auto-detect: Kintsugi/Lua header means compile
  let source = readFile(filePath)
  if source.strip.startsWith("Kintsugi/Lua"):
    compileLua(filePath, outPath)
  else:
    runFile(filePath)

main()
