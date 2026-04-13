## Golden output runner.
##
## For each .ktg file in tests/golden/, compile via emitLua (entrypoint,
## has Kintsugi [...] header) or emitLuaModule (module, no header) and
## compare LF-normalized byte-identical against the sibling .lua file.
##
## Usage:
##   nim c -r tests/test_golden.nim                    # run comparisons
##   KINTSUGI_UPDATE_GOLDENS=1 nim c -r tests/test_golden.nim  # rewrite goldens
##
## Golden update uses an env var (not a CLI flag) because Nim unittest
## interprets unrecognised CLI params as test-name filters, which would
## silently skip every test. The env var is the explicit opt-in.

import std/[unittest, os, strutils, algorithm]
import ../src/parse/parser
import ../src/emit/lua
import ../src/eval/[evaluator, natives]
import ../src/dialects/[loop_dialect, match_dialect, object_dialect,
                        attempt_dialect, parse_dialect]

proc hasHeader(source: string): bool =
  source.strip.startsWith("Kintsugi")

proc setupEvalForTest(): Evaluator =
  result = newEvaluator()
  result.registerNatives()
  result.registerDialect(newLoopDialect())
  result.registerMatch()
  result.registerObjectDialect()
  result.registerAttempt()
  result.registerParse()
  # NOT loadStdlib() - tests compile goldens that are self-contained.

proc compileKtg(ktgPath: string): string =
  ## Mirrors src/kintsugi.nim's compileOne without file IO for the output.
  let content = readFile(ktgPath)
  let isEntrypoint = hasHeader(content)
  let source = applyUsingHeader(content)
  let ast = parseSource(source)
  let eval = setupEvalForTest()
  let processed = eval.preprocess(ast, forCompilation = true)
  let sourceDir = parentDir(absolutePath(ktgPath))
  if isEntrypoint:
    emitLua(processed, sourceDir)
  else:
    emitLuaModule(processed, sourceDir)

proc normalize(s: string): string =
  ## LF-normalize. Do NOT strip trailing whitespace or collapse blank lines -
  ## those are part of output quality.
  s.replace("\r\n", "\n").replace("\r", "\n")

proc listKtgFiles(): seq[string] =
  ## Returns absolute paths to every .ktg file in tests/golden/, sorted.
  let dir = currentSourcePath().parentDir / "golden"
  for path in walkDir(dir):
    if path.path.endsWith(".ktg"):
      result.add(path.path)
  result.sort()

proc unifiedDiff(expected, actual: string, path: string): string =
  ## Minimal diff output - line-by-line with - / + markers.
  let eLines = expected.split('\n')
  let aLines = actual.split('\n')
  result = "--- expected: " & path & "\n+++ actual\n"
  let maxLines = max(eLines.len, aLines.len)
  var shown = 0
  for i in 0 ..< maxLines:
    let eLine = if i < eLines.len: eLines[i] else: "<EOF>"
    let aLine = if i < aLines.len: aLines[i] else: "<EOF>"
    if eLine != aLine:
      result.add("@@ line " & $(i + 1) & " @@\n")
      result.add("-" & eLine & "\n")
      result.add("+" & aLine & "\n")
      shown += 1
      if shown >= 10:
        result.add("... (truncated after 10 differences)\n")
        break

# --- main ---

let update = getEnv("KINTSUGI_UPDATE_GOLDENS") == "1"
let goldenFiles = listKtgFiles()

suite "golden output":
  for ktgPath in goldenFiles:
    let luaPath = ktgPath.changeFileExt("lua")
    let name = ktgPath.extractFilename

    test name:
      let actual = normalize(compileKtg(ktgPath))
      if update:
        writeFile(luaPath, actual)
        echo "  [updated] ", luaPath.extractFilename
        check true
      else:
        if not fileExists(luaPath):
          echo "  [missing] ", luaPath
          check false
        else:
          let expected = normalize(readFile(luaPath))
          if expected != actual:
            echo unifiedDiff(expected, actual, luaPath)
            check false
          else:
            check true
