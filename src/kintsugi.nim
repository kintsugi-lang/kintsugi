## Kintsugi programming language — CLI entry point.
##
## Usage:
##   kintsugi                  — start REPL
##   kintsugi <file|dir>       — run a file or directory
##   kintsugi -e <expr>        — evaluate expression
##   kintsugi -c <file|dir>    — compile to Lua
##   kintsugi -c <file> -o <out> — compile to specific output
##   kintsugi -c <file|dir> --dry-run — print compiled Lua to stdout

import std/[os, strutils, algorithm, tables]
import core/[types, errors]
import parse/parser
import eval/[dialect, evaluator, natives]
import emit/lua
import dialects/[loop_dialect, match_dialect, object_dialect, attempt_dialect, parse_dialect]

const VERSION = "0.4.0"

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

proc loadStdlib(eval: Evaluator) =
  ## Load stdlib modules under std/math, std/collections.
  let stdCtx = newContext()
  let libDir = getAppDir() / "lib"
  # Fallback: try relative to CWD
  let searchDirs = [libDir, getCurrentDir() / "lib"]

  for dir in searchDirs:
    let mathPath = dir / "math.ktg"
    let collectionsPath = dir / "collections.ktg"
    if fileExists(mathPath) and fileExists(collectionsPath):
      # Load math
      let mathSource = stripHeader(readFile(mathPath))
      let mathCtx = newContext(eval.global)
      mathCtx.localOnly = true
      discard eval.evalBlock(parseSource(mathSource), mathCtx)
      stdCtx.set("math", KtgValue(kind: vkContext, ctx: mathCtx, line: 0))

      # Load collections
      let colSource = stripHeader(readFile(collectionsPath))
      let colCtx = newContext(eval.global)
      colCtx.localOnly = true
      discard eval.evalBlock(parseSource(colSource), colCtx)
      stdCtx.set("collections", KtgValue(kind: vkContext, ctx: colCtx, line: 0))
      break

  eval.global.set("std", KtgValue(kind: vkContext, ctx: stdCtx, line: 0))

proc applyUsing(eval: Evaluator, names: seq[KtgValue]) =
  ## Unwrap std modules into global scope.
  for name in names:
    if name.kind == vkWord and name.wordKind == wkWord:
      let moduleName = name.wordName
      if eval.global.has("std"):
        let std = eval.global.get("std")
        if std.kind == vkContext and std.ctx.has(moduleName):
          let module = std.ctx.get(moduleName)
          if module.kind == vkContext:
            for key, val in module.ctx.entries.pairs:
              eval.global.set(key, val)

proc parseHeader(source: string): (string, seq[KtgValue]) =
  ## Extract using block from Kintsugi [...] header.
  ## Returns (body-after-header, using-names).
  let trimmed = source.strip
  if not trimmed.startsWith("Kintsugi"):
    return (source, @[])

  # Parse the header block
  let ast = parseSource(source)
  var usingNames: seq[KtgValue] = @[]
  if ast.len >= 2 and ast[0].kind == vkWord and ast[0].wordName == "Kintsugi" and
     ast[1].kind == vkBlock:
    let header = ast[1].blockVals
    var i = 0
    while i < header.len:
      if header[i].kind == vkWord and header[i].wordKind == wkSetWord and
         header[i].wordName == "using":
        i += 1
        if i < header.len and header[i].kind == vkBlock:
          usingNames = header[i].blockVals
      i += 1

  (stripHeader(source), usingNames)

proc setupEval(): Evaluator =
  let eval = newEvaluator()
  eval.registerNatives()
  eval.registerDialect(newLoopDialect())
  eval.registerMatch()
  eval.registerObjectDialect()
  eval.registerAttempt()
  eval.registerParse()
  eval.loadStdlib()
  eval

proc repl() =
  proc onCtrlC() {.noconv.} =
    echo ""
    quit(0)
  setControlCHook(onCtrlC)

  let eval = setupEval()

  # Build repl context with system commands
  let replCtx = newContext()
  replCtx.set("exit", KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: "repl/exit", arity: 0, fn: proc(
        args: seq[KtgValue], ep: pointer): KtgValue =
      quit(0)
    ), line: 0))
  replCtx.set("clear", KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: "repl/clear", arity: 0, fn: proc(
        args: seq[KtgValue], ep: pointer): KtgValue =
      stdout.write("\x1b[2J\x1b[H")
      stdout.flushFile()
      ktgNone()
    ), line: 0))
  replCtx.set("version", KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: "repl/version", arity: 0, fn: proc(
        args: seq[KtgValue], ep: pointer): KtgValue =
      ktgString(VERSION)
    ), line: 0))
  replCtx.set("words", KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: "repl/words", arity: 0, fn: proc(
        args: seq[KtgValue], ep: pointer): KtgValue =
      let eval = getEvaluator(ep)
      var names: seq[KtgValue] = @[]
      for key in eval.global.entries.keys:
        names.add(ktgWord(key, wkWord))
      ktgBlock(names)
    ), line: 0))
  replCtx.set("help", KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: "repl/help", arity: 0, fn: proc(
        args: seq[KtgValue], ep: pointer): KtgValue =
      let eval = getEvaluator(ep)
      eval.output.add("repl/exit    - quit the REPL")
      eval.output.add("repl/clear   - clear the screen")
      eval.output.add("repl/version - show version")
      eval.output.add("repl/words   - list current scope bindings")
      eval.output.add("repl/help    - show this help")
      ktgNone()
    ), line: 0))
  eval.global.set("repl", KtgValue(kind: vkContext, ctx: replCtx, line: 0))

  echo "======== Kintsugi v" & VERSION & " ========"
  echo "Type expressions to evaluate. Ctrl+C to exit."
  echo ""

  while true:
    stdout.write(">> ")
    stdout.flushFile()

    var line: string
    try:
      if not stdin.readLine(line):
        echo ""
        break
    except EOFError, IOError:
      echo ""
      break

    let trimmed = line.strip
    if trimmed.len == 0:
      continue

    try:
      let result = eval.evalString(line)
      # Print any output generated by natives (like repl/help)
      for msg in eval.output:
        echo msg
      eval.output.setLen(0)
      if result.kind != vkNone:
        echo $result
    except ExitSignal as e:
      quit(e.code)
    except KtgError as e:
      echo formatError(line, e)
    except CatchableError as e:
      echo "Error: " & e.msg


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

  let rawSource = readFile(path)
  let (source, usingNames) = parseHeader(rawSource)
  let e = if eval != nil: eval else: setupEval()
  if usingNames.len > 0:
    applyUsing(e, usingNames)

  try:
    discard e.evalString(source)
  except ExitSignal as e:
    quit(e.code)
  except KtgError as ke:
    echo path & ":"
    echo formatError(source, ke)
    quit(1)
  except CatchableError as ce:
    echo "Error: " & ce.msg
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

proc compileOne(path: string, outPath: string = "", target: string = "") =
  ## Compile a single .ktg file. Header presence determines prelude.
  if not fileExists(path):
    echo "Error: file not found: " & path
    quit(1)

  let content = readFile(path)
  let isEntrypoint = hasHeader(content)
  let source = applyUsingHeader(content)
  let ast = parseSource(source)
  let eval = setupEval()
  let processed = eval.preprocess(ast, forCompilation = true, target = target)
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

proc compilePath(path: string, outPath: string = "", target: string = "") =
  if dirExists(path):
    if outPath.len > 0:
      echo "Error: -o cannot be used with directory compilation"
      quit(1)
    var count = 0
    for f in collectKtgFiles(path):
      compileOne(f, target = target)
      count += 1
    if count == 0:
      echo "No .ktg files found in: " & path
  else:
    compileOne(path, outPath, target)

proc dryRunPath(path: string, target: string = "") =
  if dirExists(path):
    for f in collectKtgFiles(path):
      let content = readFile(f)
      let isEntrypoint = hasHeader(content)
      let source = applyUsingHeader(content)
      let ast = parseSource(source)
      let eval = setupEval()
      let processed = eval.preprocess(ast, forCompilation = true, target = target)
      let sourceDir = parentDir(absolutePath(f))
      echo ";; " & f
      if isEntrypoint:
        echo emitLua(processed, sourceDir)
      else:
        echo emitLuaModule(processed, sourceDir)
  else:
    let content = readFile(path)
    let isEntrypoint = hasHeader(content)
    let source = applyUsingHeader(content)
    let ast = parseSource(source)
    let eval = setupEval()
    let processed = eval.preprocess(ast, forCompilation = true, target = target)
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
  var target = ""

  while i < args.len:
    let a = args[i]
    if a.startsWith("--target="):
      target = a["--target=".len .. ^1]
    else:
      case a
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
      of "--target":
        if i + 1 < args.len:
          i += 1
          target = args[i]
        else:
          echo "Error: --target requires a name (love2d | playdate)"
          quit(1)
      of "--dry-run":
        dryRun = true
      else:
        filePath = a
    i += 1

  if evalExpr.len > 0:
    let eval = setupEval()
    try:
      let result = eval.evalString(evalExpr)
      if result.kind != vkNone:
        echo $result
    except ExitSignal as e:
      quit(e.code)
    except KtgError as e:
      echo formatError(evalExpr, e)
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
    echo "  --target <name>              Compile target (love2d | playdate)"
    echo "                               Required when source uses @game"
    quit(1)

  if compile:
    try:
      if dryRun:
        dryRunPath(filePath, target)
      else:
        compilePath(filePath, outPath, target)
    except KtgError as e:
      # Best-effort: read the source for preview if the path is a file.
      let src = if fileExists(filePath): readFile(filePath) else: ""
      echo formatError(src, e)
      quit(1)
    except ValueError as e:
      echo "Error: " & e.msg
      quit(1)
    except CatchableError as e:
      echo "Error: " & e.msg
      quit(1)
    return

  # Default: interpret
  runFile(filePath)

main()
