## Kintsugi programming language — CLI entry point.
##
## Usage:
##   kintsugi                  — start REPL
##   kintsugi <file|dir>       — run a file or directory
##   kintsugi -e <expr>        — evaluate expression
##   kintsugi -c <file|dir>    — compile to Lua
##   kintsugi -c <file> -o <out> — compile to specific output
##   kintsugi -c <file|dir> --dry-run — print compiled Lua to stdout

import std/[os, strutils, algorithm]
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

proc hasHeader(source: string): bool =
  source.strip.startsWith("Kintsugi")

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

proc collectKtgFiles(dir: string): seq[string] =
  for f in walkDir(dir):
    if f.kind == pcFile and f.path.endsWith(".ktg"):
      result.add(f.path)
  result.sort()

# --- Interpreter ---

proc runSingleFile(path: string, eval: Evaluator = nil) =
  if not fileExists(path):
    echo "Error: file not found: " & path
    quit(1)

  let source = stripHeader(readFile(path))
  let e = if eval != nil: eval else: setupEval()

  try:
    discard e.evalString(source)
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

proc runFile(path: string) =
  if dirExists(path):
    let files = collectKtgFiles(path)
    if files.len == 0:
      echo "No .ktg files found in: " & path
      quit(1)
    let eval = setupEval()
    for f in files:
      runSingleFile(f, eval)
  else:
    runSingleFile(path)

# --- Compiler ---

proc compileOne(path: string, outPath: string = "") =
  ## Compile a single .ktg file. Header presence determines prelude.
  if not fileExists(path):
    echo "Error: file not found: " & path
    quit(1)

  let content = readFile(path)
  let isEntrypoint = hasHeader(content)
  let source = stripHeader(content)
  let ast = parseSource(source)
  let eval = setupEval()
  let processed = eval.preprocess(ast)
  let sourceDir = parentDir(absolutePath(path))

  let luaCode = if isEntrypoint:
                  emitLua(processed, sourceDir)
                else:
                  emitLuaModule(processed, sourceDir)

  if outPath.len > 0:
    writeFile(outPath, luaCode)
    echo "Compiled: " & path & " -> " & outPath
  else:
    let defaultOut = path.changeFileExt("lua")
    writeFile(defaultOut, luaCode)
    echo "Compiled: " & path & " -> " & defaultOut

proc compilePath(path: string, outPath: string = "") =
  if dirExists(path):
    if outPath.len > 0:
      echo "Error: -o cannot be used with directory compilation"
      quit(1)
    var count = 0
    for f in collectKtgFiles(path):
      compileOne(f)
      count += 1
    if count == 0:
      echo "No .ktg files found in: " & path
  else:
    compileOne(path, outPath)

proc dryRunPath(path: string) =
  if dirExists(path):
    for f in collectKtgFiles(path):
      let content = readFile(f)
      let isEntrypoint = hasHeader(content)
      let source = stripHeader(content)
      let ast = parseSource(source)
      let eval = setupEval()
      let processed = eval.preprocess(ast)
      let sourceDir = parentDir(absolutePath(f))
      echo ";; " & f
      if isEntrypoint:
        echo emitLua(processed, sourceDir)
      else:
        echo emitLuaModule(processed, sourceDir)
  else:
    let content = readFile(path)
    let isEntrypoint = hasHeader(content)
    let source = stripHeader(content)
    let ast = parseSource(source)
    let eval = setupEval()
    let processed = eval.preprocess(ast)
    let sourceDir = parentDir(absolutePath(path))
    if isEntrypoint:
      echo emitLua(processed, sourceDir)
    else:
      echo emitLuaModule(processed, sourceDir)

# --- Main ---

proc main() =
  let args = commandLineParams()

  if args.len == 0:
    repl()
    return

  var i = 0
  var compile = false
  var dryRun = false
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
    of "--dry-run":
      dryRun = true
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

  if filePath.len == 0:
    echo "Usage: kintsugi [options] [file|dir]"
    echo ""
    echo "  (no args)                    Start REPL"
    echo "  <file|dir>                   Run a file or all .ktg files in a directory"
    echo "  -e, --eval <expr>            Evaluate expression"
    echo "  -c, --compile <file|dir>     Compile to Lua (.ktg -> .lua)"
    echo "  -c <file> -o <out>           Compile to specific output file"
    echo "  -c <file|dir> --dry-run      Print compiled Lua to stdout"
    quit(1)

  if compile:
    if dryRun:
      dryRunPath(filePath)
    else:
      compilePath(filePath, outPath)
    return

  # Default: interpret
  runFile(filePath)

main()
