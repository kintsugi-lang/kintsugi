import std/[strutils, tables, sets, times, algorithm]
when not defined(js):
  import std/os
import ../core/types
import ../parse/parser
import dialect, evaluator, stdlib_registry

proc resolveStdlibModule*(eval: Evaluator, moduleName: string): KtgContext =
  if moduleName notin stdlibModules:
    raise KtgError(kind: "import", msg: "unknown module: " & moduleName, data: nil)
  let source = stripModuleHeader(stdlibModules[moduleName])
  let moduleCtx = newContext(eval.global)
  moduleCtx.localOnly = true
  let ast = parseSource(source)
  discard eval.evalBlock(ast, moduleCtx)
  moduleCtx

proc native(ctx: KtgContext, name: string, arity: int, fn: NativeFnProc) =
  ctx.set(name, KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: name, arity: arity, fn: fn),
    line: 0))

proc registerIoNatives*(eval: Evaluator) =
  let ctx = eval.global

  # --- byte/char: character code conversion ---

  ctx.native("byte", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind != vkString or args[0].strVal.len == 0:
      raise KtgError(kind: "type", msg: "byte expects non-empty string!", data: nil)
    ktgInt(int64(ord(args[0].strVal[0])))
  )

  ctx.native("char", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind != vkInteger:
      raise KtgError(kind: "type", msg: "char expects integer!", data: nil)
    let code = int(args[0].intVal)
    if code < 0 or code > 255:
      raise KtgError(kind: "range", msg: "char code must be 0-255", data: args[0])
    ktgString($chr(code))
  )

  when not defined(js):
    # --- read: unified input primitive ---
    block:
      let readNative = KtgNative(
        name: "read",
        arity: 1,
        refinements: @[
          RefinementSpec(name: "dir", params: @[]),
          RefinementSpec(name: "lines", params: @[]),
          RefinementSpec(name: "stdin", params: @[])
        ],
        fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
          let eval = getEvaluator(ep)

          if "stdin" in eval.currentRefinements:
            let prompt = $args[0]
            if prompt.len > 0 and prompt != "none":
              stdout.write(prompt)
              stdout.flushFile()
            var line: string
            if stdin.readLine(line):
              return ktgString(line)
            return ktgNone()

          let path = case args[0].kind
            of vkString: args[0].strVal
            of vkFile: args[0].filePath
            else:
              raise KtgError(kind: "type", msg: "read expects string! or file!", data: nil)

          if "dir" in eval.currentRefinements:
            if not dirExists(path):
              raise KtgError(kind: "io", msg: "directory not found: " & path, data: args[0])
            var entries: seq[KtgValue] = @[]
            for kind, entry in walkDir(path):
              entries.add(ktgString(lastPathPart(entry)))
            entries.sort(proc(a, b: KtgValue): int = cmp(a.strVal, b.strVal))
            return ktgBlock(entries)

          if "lines" in eval.currentRefinements:
            if not fileExists(path):
              raise KtgError(kind: "io", msg: "file not found: " & path, data: args[0])
            let content = readFile(path)
            var lines: seq[KtgValue] = @[]
            for line in content.splitLines:
              lines.add(ktgString(line))
            return ktgBlock(lines)

          if not fileExists(path):
            raise KtgError(kind: "io", msg: "file not found: " & path, data: args[0])
          ktgString(readFile(path))
      )
      ctx.set("read", KtgValue(kind: vkNative, nativeFn: readNative, line: 0))

  when not defined(js):
    # --- write ---
    ctx.native("write", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
      let path = case args[0].kind
        of vkString: args[0].strVal
        of vkFile: args[0].filePath
        else:
          raise KtgError(kind: "type", msg: "write expects string! or file!", data: nil)
      if args[1].kind != vkString:
        raise KtgError(kind: "type", msg: "write expects string! as content", data: nil)
      writeFile(path, args[1].strVal)
      ktgNone()
    )

  when not defined(js):
    ctx.native("dir?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
      let path = case args[0].kind
        of vkString: args[0].strVal
        of vkFile: args[0].filePath
        else:
          raise KtgError(kind: "type", msg: "dir? expects string! or file!", data: nil)
      ktgLogic(dirExists(path))
    )

  when not defined(js):
    ctx.native("file?", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
      let path = case args[0].kind
        of vkString: args[0].strVal
        of vkFile: args[0].filePath
        else:
          raise KtgError(kind: "type", msg: "file? expects string! or file!", data: nil)
      ktgLogic(fileExists(path))
    )

  ctx.native("exit", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let code = case args[0].kind
      of vkInteger: int(args[0].intVal)
      else: 0
    raise ExitSignal(code: code)
  )

  # --- Time ---

  ctx.native("now", 0, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgInt(toUnix(getTime()))
  )

  block:
    let timeCtx = newContext()
    timeCtx.set("now", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "time/now", arity: 0, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        let t = now()
        KtgValue(kind: vkTime, hour: uint8(t.hour), minute: uint8(t.minute),
                 second: uint8(t.second), line: 0)
      ), line: 0))
    timeCtx.set("from-epoch", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "time/from-epoch", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkInteger:
          raise KtgError(kind: "type", msg: "time/from-epoch expects integer!", data: nil)
        let dt = fromUnix(args[0].intVal).local
        KtgValue(kind: vkTime, hour: uint8(dt.hour), minute: uint8(dt.minute),
                 second: uint8(dt.second), line: 0)
      ), line: 0))
    proc timeAccessor(ctxName, field: string, extract: proc(v: KtgValue): int64): KtgValue =
      KtgValue(kind: vkNative,
        nativeFn: KtgNative(name: ctxName & "/" & field, arity: 1, fn: proc(
            args: seq[KtgValue], ep: pointer): KtgValue =
          if args[0].kind != vkTime:
            raise KtgError(kind: "type", msg: ctxName & "/" & field & " expects time!", data: nil)
          ktgInt(extract(args[0]))
        ), line: 0)
    timeCtx.set("hours", timeAccessor("time", "hours", proc(v: KtgValue): int64 = int64(v.hour)))
    timeCtx.set("minutes", timeAccessor("time", "minutes", proc(v: KtgValue): int64 = int64(v.minute)))
    timeCtx.set("seconds", timeAccessor("time", "seconds", proc(v: KtgValue): int64 = int64(v.second)))
    timeCtx.set("to-seconds", timeAccessor("time", "to-seconds", proc(v: KtgValue): int64 =
      int64(v.hour) * 3600 + int64(v.minute) * 60 + int64(v.second)))
    ctx.set("time", KtgValue(kind: vkContext, ctx: timeCtx, line: 0))

  block:
    let dateCtx = newContext()
    dateCtx.set("now", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "date/now", arity: 0, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        let d = now()
        KtgValue(kind: vkDate, year: int16(d.year), month: uint8(ord(d.month)),
                 day: uint8(d.monthday), line: 0)
      ), line: 0))
    dateCtx.set("from-epoch", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "date/from-epoch", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkInteger:
          raise KtgError(kind: "type", msg: "date/from-epoch expects integer!", data: nil)
        let dt = fromUnix(args[0].intVal).local
        KtgValue(kind: vkDate, year: int16(dt.year), month: uint8(ord(dt.month)),
                 day: uint8(dt.monthday), line: 0)
      ), line: 0))
    proc dateAccessor(ctxName, field: string, extract: proc(v: KtgValue): int64): KtgValue =
      KtgValue(kind: vkNative,
        nativeFn: KtgNative(name: ctxName & "/" & field, arity: 1, fn: proc(
            args: seq[KtgValue], ep: pointer): KtgValue =
          if args[0].kind != vkDate:
            raise KtgError(kind: "type", msg: ctxName & "/" & field & " expects date!", data: nil)
          ktgInt(extract(args[0]))
        ), line: 0)
    dateCtx.set("year", dateAccessor("date", "year", proc(v: KtgValue): int64 = int64(v.year)))
    dateCtx.set("month", dateAccessor("date", "month", proc(v: KtgValue): int64 = int64(v.month)))
    dateCtx.set("day", dateAccessor("date", "day", proc(v: KtgValue): int64 = int64(v.day)))
    dateCtx.set("weekday", KtgValue(kind: vkNative,
      nativeFn: KtgNative(name: "date/weekday", arity: 1, fn: proc(
          args: seq[KtgValue], ep: pointer): KtgValue =
        if args[0].kind != vkDate:
          raise KtgError(kind: "type", msg: "date/weekday expects date!", data: nil)
        let dt = dateTime(int(args[0].year), Month(args[0].month), MonthdayRange(args[0].day), 0, 0, 0)
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        ktgString(names[ord(dt.weekday)])
      ), line: 0))
    ctx.set("date", KtgValue(kind: vkContext, ctx: dateCtx, line: 0))

  when not defined(js):
    # --- Load ---

    block:
      let loadNative = KtgNative(
        name: "load",
        arity: 1,
        refinements: @[
          RefinementSpec(name: "eval", params: @[]),
          RefinementSpec(name: "header", params: @[]),
          RefinementSpec(name: "freeze", params: @[])
        ],
        fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
          let eval = getEvaluator(ep)
          let doFreeze = "freeze" in eval.currentRefinements
          let path = case args[0].kind
            of vkString: args[0].strVal
            of vkFile: args[0].filePath
            else: raise KtgError(kind: "type", msg: "load expects string! or file!", data: nil)

          let content = readFile(path)
          let ast = parseSource(content)

          if "header" in eval.currentRefinements:
            if ast.len >= 2 and ast[0].kind == vkWord and ast[0].wordKind == wkWord and
               ast[0].wordName == "Kintsugi" and ast[1].kind == vkBlock:
              return ast[1]
            return ktgNone()

          if "eval" in eval.currentRefinements:
            let isoCtx = newContext(eval.global)
            isoCtx.localOnly = true
            discard eval.evalBlock(ast, isoCtx)
            if doFreeze:
              return KtgValue(kind: vkObject,
                obj: newObject(isoCtx.entries), line: 0)
            return KtgValue(kind: vkContext, ctx: isoCtx, line: 0)

          if doFreeze:
            let isoCtx = newContext(eval.global)
            isoCtx.localOnly = true
            discard eval.evalBlock(ast, isoCtx)
            return KtgValue(kind: vkObject,
              obj: newObject(isoCtx.entries), line: 0)

          return ktgBlock(ast)
      )
      ctx.set("load", KtgValue(kind: vkNative, nativeFn: loadNative, line: 0))

  when not defined(js):
    # --- Save ---

    ctx.native("save", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
      let path = case args[0].kind
        of vkString: args[0].strVal
        of vkFile: args[0].filePath
        else: raise KtgError(kind: "type", msg: "save expects string! or file! as first arg", data: nil)

      proc serialize(val: KtgValue): string =
        case val.kind
        of vkString:
          "\"" & val.strVal.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
        of vkBlock:
          var s = "["
          for i, v in val.blockVals:
            if i > 0: s &= " "
            s &= serialize(v)
          s & "]"
        of vkContext:
          var s = ""
          var first = true
          for key, v in val.ctx.entries:
            if v.kind in {vkFunction, vkNative}: continue
            if key == "self": continue
            if not first: s &= "\n"
            s &= key & ": " & serialize(v)
            first = false
          s
        of vkObject:
          var s = ""
          var first = true
          for key, v in val.obj.entries:
            if v.kind in {vkFunction, vkNative}: continue
            if not first: s &= "\n"
            s &= key & ": " & serialize(v)
            first = false
          s
        of vkMap:
          var s = "make map! ["
          var first = true
          for key, v in val.mapEntries:
            if not first: s &= " "
            s &= key & ": " & serialize(v)
            first = false
          s & "]"
        of vkFunction, vkNative:
          ""
        else:
          $val

      writeFile(path, serialize(args[1]))
      ktgNone()
    )

  # --- Import (stdlib via lit-words, works on all backends) ---

  block:
    var importRefinements = @[
      RefinementSpec(name: "using", params: @[ParamSpec(name: "symbols")])
    ]
    when not defined(js):
      importRefinements.add(RefinementSpec(name: "fresh", params: @[]))

    let importNative = KtgNative(
      name: "import",
      arity: 1,
      refinements: importRefinements,
      fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
        let eval = getEvaluator(ep)

        # --- Lit-word: import 'math ---
        if args[0].kind == vkWord and args[0].wordKind == wkLitWord:
          let moduleName = args[0].wordName
          let moduleCtx = resolveStdlibModule(eval, moduleName)
          if "using" in eval.currentRefinements:
            let symbols = args[1]
            if symbols.kind != vkBlock:
              raise KtgError(kind: "type", msg: "import/using expects block! of symbols", data: nil)
            for sym in symbols.blockVals:
              if sym.kind != vkWord:
                raise KtgError(kind: "type", msg: "import/using expects words in symbol list", data: nil)
              let name = sym.wordName
              if not moduleCtx.has(name):
                raise KtgError(kind: "import",
                  msg: "module '" & moduleName & "' has no export: " & name, data: nil)
              eval.currentCtx.set(name, moduleCtx.get(name))
            return ktgNone()
          let moduleVal = KtgValue(kind: vkContext, ctx: moduleCtx, line: 0)
          eval.currentCtx.set(moduleName, moduleVal)
          return moduleVal

        # --- Block of lit-words: import ['math 'collections] ---
        if args[0].kind == vkBlock:
          var lastVal: KtgValue = ktgNone()
          for item in args[0].blockVals:
            if item.kind != vkWord or item.wordKind != wkLitWord:
              raise KtgError(kind: "type",
                msg: "import block expects lit-words, got " & $item, data: nil)
            let moduleName = item.wordName
            let moduleCtx = resolveStdlibModule(eval, moduleName)
            let moduleVal = KtgValue(kind: vkContext, ctx: moduleCtx, line: 0)
            eval.currentCtx.set(moduleName, moduleVal)
            lastVal = moduleVal
          return lastVal

        when not defined(js):
          # --- File path: import %path (native only, needs filesystem) ---
          let rawPath = case args[0].kind
            of vkString: args[0].strVal
            of vkFile: args[0].filePath
            else: raise KtgError(kind: "type", msg: "import expects lit-word!, block!, string! or file!", data: nil)

          let resolvedPath = if rawPath.isAbsolute: rawPath else: getCurrentDir() / rawPath

          if "fresh" notin eval.currentRefinements and resolvedPath in eval.moduleCache:
            return eval.moduleCache[resolvedPath]

          if resolvedPath in eval.moduleLoading:
            raise KtgError(kind: "load",
              msg: "circular dependency detected: " & resolvedPath,
              data: nil)

          eval.moduleLoading.incl(resolvedPath)

          try:
            let content = readFile(resolvedPath)
            var ast = parseSource(content)

            if ast.len >= 2 and ast[0].kind == vkWord and ast[0].wordKind == wkWord and
               ast[0].wordName == "Kintsugi" and ast[1].kind == vkBlock:
              ast = ast[2..^1]

            let isoCtx = newContext(eval.global)
            isoCtx.localOnly = true
            discard eval.evalBlock(ast, isoCtx)

            var resultCtx: KtgContext
            if isoCtx.has("__exports"):
              let exportsVal = isoCtx.get("__exports")
              if exportsVal.kind == vkBlock:
                resultCtx = newContext()
                for v in exportsVal.blockVals:
                  if v.kind == vkWord:
                    let name = v.wordName
                    if isoCtx.has(name):
                      resultCtx.set(name, isoCtx.get(name))
              else:
                resultCtx = isoCtx
            else:
              resultCtx = isoCtx

            let res = KtgValue(kind: vkContext, ctx: resultCtx, line: 0)

            eval.moduleLoading.excl(resolvedPath)
            eval.moduleCache[resolvedPath] = res
            return res
          except KtgError:
            eval.moduleLoading.excl(resolvedPath)
            raise
          except CatchableError:
            eval.moduleLoading.excl(resolvedPath)
            raise
        else:
          raise KtgError(kind: "type", msg: "import expects lit-word! or block! on this backend", data: nil)
    )
    ctx.set("import", KtgValue(kind: vkNative, nativeFn: importNative, line: 0))

  # --- Exports ---

  ctx.native("exports", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "exports expects block!", data: nil)
    eval.currentCtx.set("__exports", args[0])
    ktgNone()
  )

  # --- Bindings (compile-time dialect for foreign API declarations) ---

  ctx.native("bindings", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    let eval = getEvaluator(ep)
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "bindings expects block!", data: nil)

    let blk = args[0].blockVals
    var pos = 0
    while pos < blk.len:
      if pos >= blk.len: break
      let nameVal = blk[pos]
      if nameVal.kind != vkWord or nameVal.wordKind != wkWord:
        pos += 1
        continue
      let name = nameVal.wordName
      pos += 1

      if pos >= blk.len: break
      let pathVal = blk[pos]
      if pathVal.kind != vkString:
        pos += 1
        continue
      pos += 1

      if pos >= blk.len: break
      let kindVal = blk[pos]
      if kindVal.kind != vkWord or kindVal.wordKind != wkLitWord:
        pos += 1
        continue
      let kindName = kindVal.wordName
      pos += 1

      case kindName
      of "call":
        var arity = 0
        if pos < blk.len and blk[pos].kind == vkInteger:
          arity = int(blk[pos].intVal)
          pos += 1
        let capturedArity = arity
        let capturedName = name
        eval.currentCtx.set(name, KtgValue(kind: vkNative,
          nativeFn: KtgNative(name: capturedName, arity: capturedArity,
            fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
              ktgNone()
          ), line: 0))
      of "const":
        eval.currentCtx.set(name, ktgNone())
      of "alias":
        eval.currentCtx.set(name, ktgNone())
      of "assign":
        let capturedName = name
        eval.currentCtx.set(name, KtgValue(kind: vkNative,
          nativeFn: KtgNative(name: capturedName, arity: 1,
            fn: proc(args: seq[KtgValue], ep: pointer): KtgValue =
              ktgNone()
          ), line: 0))
      else:
        discard

    ktgNone()
  )

  # --- emit / raw (no-ops at top level; functional inside #preprocess / compiler) ---
  ctx.native("emit", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgNone()
  )

  ctx.native("raw", 1, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    ktgNone()
  )

  # --- system: platform, env ---
  block:
    let envCtx = newContext()
    when not defined(js):
      for key, value in envPairs():
        envCtx.set(key, ktgString(value))

    let systemCtx = newContext()
    systemCtx.set("platform", ktgWord("script", wkLitWord))
    systemCtx.set("env", KtgValue(kind: vkContext, ctx: envCtx, line: 0))
    ctx.set("system", KtgValue(kind: vkContext, ctx: systemCtx, line: 0))

  # --- capture: declarative keyword extraction from blocks ---

  ctx.native("capture", 2, proc(args: seq[KtgValue], ep: pointer): KtgValue =
    if args[0].kind != vkBlock:
      raise KtgError(kind: "type", msg: "capture expects block! as first argument", data: nil)
    if args[1].kind != vkBlock:
      raise KtgError(kind: "type", msg: "capture expects block! as schema", data: nil)

    let data = args[0].blockVals
    let schema = args[1].blockVals

    type CaptureSpec = object
      keyword: string
      bindName: string
      exact: int

    var specs: seq[CaptureSpec] = @[]
    var allKeywords: seq[string] = @[]

    for s in schema:
      if s.kind != vkWord or s.wordKind != wkMetaWord:
        continue
      let fullName = s.wordName
      let parts = fullName.split('/')
      var keyword = fullName
      var exact = -1

      if parts.len >= 2:
        var allDigits = true
        for c in parts[^1]:
          if c notin {'0'..'9'}:
            allDigits = false
            break
        if allDigits and parts[^1].len > 0:
          exact = parseInt(parts[^1])
          keyword = parts[0 .. ^2].join("/")

      specs.add(CaptureSpec(keyword: keyword, bindName: keyword, exact: exact))
      allKeywords.add(keyword)

    let resultCtx = newContext()

    for spec in specs:
      resultCtx.set(spec.bindName, ktgNone())

    var pos = 0
    while pos < data.len:
      let val = data[pos]

      var matched = false
      for spec in specs:
        if val.kind == vkWord and val.wordKind == wkWord and val.wordName == spec.keyword:
          pos += 1
          matched = true

          if spec.exact >= 0:
            var captured: seq[KtgValue] = @[]
            for j in 0 ..< spec.exact:
              if pos < data.len:
                captured.add(data[pos])
                pos += 1
            let existing = resultCtx.get(spec.bindName)
            if existing.kind == vkNone:
              if captured.len == 1:
                resultCtx.set(spec.bindName, captured[0])
              else:
                resultCtx.set(spec.bindName, ktgBlock(captured))
            else:
              var collected: seq[KtgValue] = @[]
              if existing.kind == vkBlock:
                for v in existing.blockVals:
                  collected.add(v)
              else:
                collected.add(existing)
              for v in captured:
                collected.add(v)
              resultCtx.set(spec.bindName, ktgBlock(collected))
          else:
            var captured: seq[KtgValue] = @[]
            while pos < data.len:
              let cur = data[pos]
              if cur.kind == vkWord and cur.wordKind == wkWord and
                 cur.wordName in allKeywords and cur.wordName != spec.keyword:
                break
              if cur.kind == vkWord and cur.wordKind == wkWord and
                 cur.wordName == spec.keyword:
                pos += 1
                continue
              captured.add(cur)
              pos += 1
            if captured.len == 0:
              resultCtx.set(spec.bindName, ktgNone())
            elif captured.len == 1:
              resultCtx.set(spec.bindName, captured[0])
            else:
              resultCtx.set(spec.bindName, ktgBlock(captured))
          break

      if not matched:
        pos += 1

    KtgValue(kind: vkContext, ctx: resultCtx, line: 0)
  )
