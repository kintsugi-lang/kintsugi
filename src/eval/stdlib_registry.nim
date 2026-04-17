import std/[strutils, tables, sets, sequtils]
import ../core/types
import ../parse/parser

const stdlibModules* = {
  "math": staticRead("../../lib/math.ktg"),
  "collections": staticRead("../../lib/collections.ktg"),
}.toTable

proc stripModuleHeader*(source: string): string =
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

type FuncDef = object
  name: string
  startIdx: int
  endIdx: int
  bodyRefs: HashSet[string]

proc collectRefs(vals: seq[KtgValue]): HashSet[string] =
  for v in vals:
    case v.kind
    of vkWord:
      if v.wordKind in {wkWord, wkGetWord, wkLitWord}:
        result.incl(v.wordName)
    of vkBlock: result = result + collectRefs(v.blockVals)
    of vkParen: result = result + collectRefs(v.parenVals)
    else: discard

proc selectiveModuleAst*(moduleName: string): (seq[KtgValue], seq[FuncDef]) =
  let source = stripModuleHeader(stdlibModules[moduleName])
  let ast = parseSource(source)
  var defs: seq[FuncDef]
  var i = 0
  while i < ast.len:
    if ast[i].kind == vkWord and ast[i].wordKind == wkSetWord:
      let name = ast[i].wordName
      let startIdx = i
      i += 1
      if i < ast.len and ast[i].kind == vkWord and ast[i].wordKind == wkWord and
         ast[i].wordName == "function" and i + 2 < ast.len and
         ast[i + 1].kind == vkBlock and ast[i + 2].kind == vkBlock:
        let bodyRefs = collectRefs(ast[i + 2].blockVals)
        defs.add(FuncDef(name: name, startIdx: startIdx, endIdx: i + 3, bodyRefs: bodyRefs))
        i += 3
        continue
      elif i < ast.len and ast[i].kind == vkWord and ast[i].wordKind == wkWord and
           ast[i].wordName == "does" and i + 1 < ast.len and
           ast[i + 1].kind == vkBlock:
        let bodyRefs = collectRefs(ast[i + 1].blockVals)
        defs.add(FuncDef(name: name, startIdx: startIdx, endIdx: i + 2, bodyRefs: bodyRefs))
        i += 2
        continue
    i += 1
  (ast, defs)

proc moduleExports*(moduleName: string): seq[string] =
  ## Names of every top-level function defined in the named stdlib module.
  ## Used by the Lua emitter to expand whole-module imports into prelude.
  let (_, defs) = selectiveModuleAst(moduleName)
  for d in defs: result.add(d.name)

proc spliceSelectedFunctions*(moduleName: string, symbols: seq[string]): seq[KtgValue] =
  let (ast, defs) = selectiveModuleAst(moduleName)
  let defNames = defs.mapIt(it.name).toHashSet

  var needed = symbols.toHashSet
  var changed = true
  while changed:
    changed = false
    for d in defs:
      if d.name in needed:
        for r in d.bodyRefs:
          if r in defNames and r notin needed:
            needed.incl(r)
            changed = true

  for d in defs:
    if d.name in needed:
      for idx in d.startIdx ..< d.endIdx:
        result.add(ast[idx])
