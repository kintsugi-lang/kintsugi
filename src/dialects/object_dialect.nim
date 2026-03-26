import std/[tables]
import ../core/types
import ../eval/[dialect, evaluator]

## Object dialect — prototype-based object system.
##
## `object [spec]` — creates an immutable object! (prototype)
##   Field declarations use the `field` keyword:
##     field [name [type!]]         — required field
##     field [name [type!] default] — field with initial value
##   Everything else in the block is the prototype body (methods)
##
## `make Prototype [overrides]` — stamps a mutable context! (instance)
##   Shallow copies fields, applies overrides, validates required fields,
##   binds `self` in each method's closure.
##
## Auto-generation: when assigned to a set-word (e.g., `Person: object [...]`),
##   auto-generates `person!` type predicate and `make-person` constructor.
##   Handled in the evaluator's set-word handler.


proc parseFieldDecl(fieldBlock: seq[KtgValue]): FieldSpec =
  ## Parse a single field declaration block:
  ##   [name [type!]]         — required
  ##   [name [type!] default] — with default value
  if fieldBlock.len < 2:
    raise KtgError(kind: "object",
      msg: "field declaration needs at least name and type: field [name [type!]]",
      data: nil)

  let nameVal = fieldBlock[0]
  if nameVal.kind != vkWord or nameVal.wordKind != wkWord:
    raise KtgError(kind: "object",
      msg: "field name must be a word, got " & typeName(nameVal),
      data: nil)

  let typeBlockVal = fieldBlock[1]
  if typeBlockVal.kind != vkBlock or typeBlockVal.blockVals.len == 0:
    raise KtgError(kind: "object",
      msg: "field type must be a non-empty block [type!]",
      data: nil)

  let fieldTypeName = $typeBlockVal.blockVals[0]

  if fieldBlock.len >= 3:
    # Has default value
    FieldSpec(
      name: nameVal.wordName,
      typeName: fieldTypeName,
      hasDefault: true,
      defaultVal: fieldBlock[2]
    )
  else:
    # Required field
    FieldSpec(
      name: nameVal.wordName,
      typeName: fieldTypeName,
      hasDefault: false,
      defaultVal: nil
    )


proc parseObjectBlock(blk: seq[KtgValue], bodyStart: var int): seq[FieldSpec] =
  ## Walk the object spec block. Extract `field [...]` declarations.
  ## Everything that isn't a `field` keyword is part of the body.
  var specs: seq[FieldSpec] = @[]
  var pos = 0

  while pos < blk.len:
    let current = blk[pos]

    # Check for `field` keyword followed by a block
    if current.kind == vkWord and current.wordKind == wkWord and
       current.wordName == "field" and
       pos + 1 < blk.len and blk[pos + 1].kind == vkBlock:
      let fieldBlock = blk[pos + 1].blockVals
      specs.add(parseFieldDecl(fieldBlock))
      pos += 2
    else:
      # Not a field declaration — this is where the body starts
      break

  bodyStart = pos
  specs


proc cloneFuncWithSelf(fn: KtgFunc, selfCtx: KtgContext): KtgFunc =
  ## Create a copy of a function with `self` bound in its closure.
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
      let eval = cast[Evaluator](ep)
      let spec = args[0]

      if spec.kind != vkBlock:
        raise KtgError(kind: "type",
          msg: "object expects a spec block",
          data: spec)

      let blk = spec.blockVals

      # Parse field declarations
      var bodyStart = 0
      var fieldSpecs = parseObjectBlock(blk, bodyStart)

      # Build entries — start with field defaults or none
      var entries = initOrderedTable[string, KtgValue]()
      for fs in fieldSpecs:
        if fs.hasDefault:
          entries[fs.name] = fs.defaultVal
        else:
          entries[fs.name] = ktgNone()

      # Evaluate the body (method definitions, additional init)
      if bodyStart < blk.len:
        let bodyCtx = newContext(eval.currentCtx)
        # Pre-populate fields so body can reference them
        for fs in fieldSpecs:
          if fs.hasDefault:
            bodyCtx.set(fs.name, fs.defaultVal)
          else:
            bodyCtx.set(fs.name, ktgNone())
        let body = blk[bodyStart .. ^1]
        discard eval.evalBlock(body, bodyCtx)
        # Copy all definitions from body into entries
        for key, val in bodyCtx.entries:
          entries[key] = val

      # Create the frozen object
      let obj = newObject(entries, fieldSpecs)
      KtgValue(kind: vkObject, obj: obj, line: 0)
    ),
    line: 0))


  # --- make native: arity 2 (prototype/type + overrides block) ---

  ctx.set("make", KtgValue(kind: vkNative,
    nativeFn: KtgNative(name: "make", arity: 2, fn: proc(
        args: seq[KtgValue], ep: pointer): KtgValue =
      let eval = cast[Evaluator](ep)
      let source = args[0]
      let overrides = args[1]

      if overrides.kind != vkBlock:
        raise KtgError(kind: "type",
          msg: "make expects a block of overrides",
          data: overrides)

      # Determine what we're making from
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
          msg: "make expects an object! or context! as first argument, got " &
               typeName(source),
          data: source)

      # Create the new instance context
      let instance = newContext(eval.global)

      # Step 1: Shallow copy all entries from source
      for key, val in sourceEntries:
        instance.set(key, val)

      # Step 2: Apply overrides from the block
      let overrideCtx = newContext(eval.currentCtx)
      if overrides.blockVals.len > 0:
        discard eval.evalBlock(overrides.blockVals, overrideCtx)
        for key, val in overrideCtx.entries:
          # Type-check overrides against field specs
          for fs in fieldSpecs:
            if fs.name == key and fs.typeName != "":
              let actual = typeName(val)
              if actual != fs.typeName:
                raise KtgError(kind: "type",
                  msg: "field '" & key & "' expects " & fs.typeName &
                       ", got " & actual,
                  data: val)
          instance.set(key, val)

      # Step 3: Validate required fields (no default = required)
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

      # Step 5: Return mutable context
      selfVal
    ),
    line: 0))
