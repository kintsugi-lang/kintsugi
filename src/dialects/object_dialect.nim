import std/[tables, sets]
import ../core/types
import ../eval/[dialect, evaluator]

## Object dialect — object system with typed fields.
##
## Field declarations:
##   field/required [name [type!]]              — one required field
##   field/optional [name [type!] default]      — one optional field (default evaluated)
##   fields [                                   — bulk declaration
##     required [name [type!] name2 [type!]]
##     optional [name [type!] default ...]
##   ]
##
## `make Object [overrides]` — stamps a mutable context! (instance)
## Auto-generation: Person: object [...] → person!, person?, make-person


proc parseRequiredField(blk: seq[KtgValue], pos: var int): FieldSpec =
  ## Parse one required field: name [type!]
  if pos >= blk.len or blk[pos].kind != vkWord or blk[pos].wordKind != wkWord:
    raise KtgError(kind: "object", msg: "expected field name", data: nil)
  let name = blk[pos].wordName
  pos += 1
  if pos >= blk.len or blk[pos].kind != vkBlock or blk[pos].blockVals.len == 0:
    raise KtgError(kind: "object", msg: "expected type block [type!] for field '" & name & "'", data: nil)
  let typeName = $blk[pos].blockVals[0]
  pos += 1
  FieldSpec(name: name, typeName: typeName, hasDefault: false, defaultVal: nil)


proc parseOptionalField(blk: seq[KtgValue], pos: var int, eval: Evaluator, ctx: KtgContext): FieldSpec =
  ## Parse one optional field: name [type!] default
  ## Default value is evaluated.
  if pos >= blk.len or blk[pos].kind != vkWord or blk[pos].wordKind != wkWord:
    raise KtgError(kind: "object", msg: "expected field name", data: nil)
  let name = blk[pos].wordName
  pos += 1
  if pos >= blk.len or blk[pos].kind != vkBlock or blk[pos].blockVals.len == 0:
    raise KtgError(kind: "object", msg: "expected type block [type!] for field '" & name & "'", data: nil)
  let typeName = $blk[pos].blockVals[0]
  pos += 1
  if pos >= blk.len:
    raise KtgError(kind: "object", msg: "expected default value for field '" & name & "'", data: nil)
  # Evaluate the default value
  let defaultVal = eval.evalNext(blk, pos, ctx)
  FieldSpec(name: name, typeName: typeName, hasDefault: true, defaultVal: defaultVal)


proc parseFieldsBlock(blk: seq[KtgValue], eval: Evaluator, ctx: KtgContext): seq[FieldSpec] =
  ## Parse a fields [...] block with required/optional subsections.
  var specs: seq[FieldSpec] = @[]
  var pos = 0
  while pos < blk.len:
    let current = blk[pos]
    if current.kind == vkWord and current.wordKind == wkWord:
      case current.wordName
      of "required":
        pos += 1
        if pos >= blk.len or blk[pos].kind != vkBlock:
          raise KtgError(kind: "object", msg: "required expects a block", data: nil)
        let reqBlock = blk[pos].blockVals
        pos += 1
        var rpos = 0
        while rpos < reqBlock.len:
          specs.add(parseRequiredField(reqBlock, rpos))
      of "optional":
        pos += 1
        if pos >= blk.len or blk[pos].kind != vkBlock:
          raise KtgError(kind: "object", msg: "optional expects a block", data: nil)
        let optBlock = blk[pos].blockVals
        pos += 1
        var opos = 0
        while opos < optBlock.len:
          specs.add(parseOptionalField(optBlock, opos, eval, ctx))
      else:
        pos += 1
    else:
      pos += 1
  specs


proc parseObjectBlock(blk: seq[KtgValue], bodyStart: var int,
                       eval: Evaluator, ctx: KtgContext): seq[FieldSpec] =
  ## Walk the object spec block. Extract field declarations.
  ## Supports:
  ##   field/required [name [type!]]
  ##   field/optional [name [type!] default]
  ##   fields [required [...] optional [...]]
  var specs: seq[FieldSpec] = @[]
  var pos = 0

  while pos < blk.len:
    let current = blk[pos]

    if current.kind == vkWord and current.wordKind == wkWord:
      # fields [...] — bulk declaration
      if current.wordName == "fields" and pos + 1 < blk.len and blk[pos + 1].kind == vkBlock:
        specs.add(parseFieldsBlock(blk[pos + 1].blockVals, eval, ctx))
        pos += 2
        continue

      # field/required [...] — sugar for one required field
      if current.wordName == "field/required" and pos + 1 < blk.len and blk[pos + 1].kind == vkBlock:
        let fieldBlock = blk[pos + 1].blockVals
        var fpos = 0
        specs.add(parseRequiredField(fieldBlock, fpos))
        pos += 2
        continue

      # field/optional [...] — sugar for one optional field
      if current.wordName == "field/optional" and pos + 1 < blk.len and blk[pos + 1].kind == vkBlock:
        let fieldBlock = blk[pos + 1].blockVals
        var fpos = 0
        specs.add(parseOptionalField(fieldBlock, fpos, eval, ctx))
        pos += 2
        continue

    # Not a field declaration — body starts here
    break

  bodyStart = pos
  specs


proc cloneFuncWithSelf(fn: KtgFunc, selfCtx: KtgContext): KtgFunc =
  let newClosure = selfCtx.child
  newClosure.parent = fn.closure
  newClosure.set("self", KtgValue(kind: vkContext, ctx: selfCtx, line: 0))
  KtgFunc(
    params: fn.params,
    refinements: fn.refinements,
    returnType: fn.returnType,
    body: fn.body,
    closure: newClosure
  )


proc registerObjectDialect*(eval: Evaluator) =
  let ctx = eval.global

  # --- object native: arity 1 (takes a spec block) ---

  ctx.set("object", KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: "object", arity: 1, fn: proc(
        args: seq[KtgValue], ep: pointer): KtgValue =
      let eval = getEvaluator(ep)
      let spec = args[0]

      if spec.kind != vkBlock:
        raise KtgError(kind: "type", msg: "object expects a spec block", data: spec)

      let blk = spec.blockVals

      # Parse field declarations
      var bodyStart = 0
      var fieldSpecs = parseObjectBlock(blk, bodyStart, eval, eval.currentCtx)

      # Build entries - start with field defaults or none
      var entries = initOrderedTable[string, KtgValue]()
      for fs in fieldSpecs:
        if fs.hasDefault:
          entries[fs.name] = fs.defaultVal
        else:
          entries[fs.name] = ktgNone()

      # Evaluate the body (method definitions)
      if bodyStart < blk.len:
        let bodyCtx = newContext(eval.currentCtx)
        bodyCtx.localOnly = true
        for fs in fieldSpecs:
          if fs.hasDefault:
            bodyCtx.set(fs.name, fs.defaultVal)
          else:
            bodyCtx.set(fs.name, ktgNone())
        let body = blk[bodyStart .. ^1]
        discard eval.evalBlock(body, bodyCtx)
        for key, val in bodyCtx.entries:
          entries[key] = val

      let obj = newObject(entries, fieldSpecs)
      KtgValue(kind: vkObject, obj: obj, line: 0)
    ),
    line: 0))


  # --- make native: arity 2 (object/type + overrides block) ---

  ctx.set("make", KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: "make", arity: 2, fn: proc(
        args: seq[KtgValue], ep: pointer): KtgValue =
      let eval = getEvaluator(ep)
      let source = args[0]
      let overrides = args[1]

      # make map! [key: val ...]
      if source.kind == vkType and source.typeName == "map!":
        if overrides.kind != vkBlock:
          raise KtgError(kind: "type", msg: "make map! expects block!", data: nil)
        let ctxInner = newContext(eval.currentCtx)
        ctxInner.localOnly = true
        discard eval.evalBlock(overrides.blockVals, ctxInner)
        var entries = initOrderedTable[string, KtgValue]()
        for key, val in ctxInner.entries:
          entries[key] = val
        return KtgValue(kind: vkMap, mapEntries: entries, line: 0)

      # make set! [values...]
      if source.kind == vkType and source.typeName == "set!":
        if overrides.kind != vkBlock:
          raise KtgError(kind: "type", msg: "make set! expects block!", data: nil)
        var members = initHashSet[string]()
        var pos = 0
        while pos < overrides.blockVals.len:
          var v = eval.evalNext(overrides.blockVals, pos, eval.currentCtx)
          eval.applyInfix(v, overrides.blockVals, pos, eval.currentCtx)
          members.incl($v)
        return KtgValue(kind: vkSet, setMembers: members, line: 0)

      if overrides.kind != vkBlock:
        raise KtgError(kind: "type", msg: "make expects a block of overrides", data: overrides)

      var sourceEntries: OrderedTable[string, KtgValue]
      var fieldSpecs: seq[FieldSpec] = @[]

      case source.kind
      of vkObject:
        sourceEntries = source.obj.entries
        fieldSpecs = source.obj.fieldSpecs
      of vkContext:
        sourceEntries = source.ctx.entries
      else:
        raise KtgError(kind: "type",
          msg: "make expects an object! or context! as first argument, got " & typeName(source),
          data: source)

      let instance = newContext(eval.global)
      ## Tag the instance with its source object's name so `type` can
      ## report it as the user-declared type instead of bare `context!`.
      if source.kind == vkObject and source.obj.name.len > 0:
        instance.instanceOf = source.obj.name

      # Step 1: Shallow copy all entries from source
      for key, val in sourceEntries:
        instance.set(key, val)

      # Step 2: Apply overrides (type-checked)
      let overrideCtx = newContext(eval.currentCtx)
      overrideCtx.localOnly = true
      if overrides.blockVals.len > 0:
        discard eval.evalBlock(overrides.blockVals, overrideCtx)
        for key, val in overrideCtx.entries:
          for fs in fieldSpecs:
            if fs.name == key and fs.typeName != "":
              let actual = typeName(val)
              if not eval.typeMatches(actual, fs.typeName, val, eval.currentCtx):
                raise KtgError(kind: "type",
                  msg: "field '" & key & "' expects " & fs.typeName & ", got " & actual,
                  data: val)
          instance.set(key, val)

      # Step 3: Validate required fields
      for fs in fieldSpecs:
        if not fs.hasDefault:
          if fs.name in instance.entries:
            let val = instance.entries[fs.name]
            if val.kind == vkNone:
              raise KtgError(kind: "make",
                msg: "required field '" & fs.name & "' was not provided",
                data: nil)
          else:
            raise KtgError(kind: "make",
              msg: "required field '" & fs.name & "' was not provided",
              data: nil)

      # Step 4: Bind self in all function values
      let selfVal = KtgValue(kind: vkContext, ctx: instance, line: 0)
      for key, val in instance.entries:
        if val.kind == vkFunction:
          let boundFn = cloneFuncWithSelf(val.fn, instance)
          instance.set(key, KtgValue(kind: vkFunction, fn: boundFn, line: 0))

      selfVal
    ),
    line: 0))
