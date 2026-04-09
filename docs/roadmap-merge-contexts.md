# Roadmap: Merge vkContext and vkPrototype

Unify `context!` and `prototype!` into a single `vkObject` variant. Both are key-value stores with optional field specs. The distinction is metadata, not structure.

---

## Why

Every layer has duplicate branches for `vkContext` and `vkPrototype`: equality, path navigation, set-path, `words-of`, `make`, type predicates, deep copy, the emitter. Merging eliminates ~100 lines of duplication and removes a class of "forgot to handle prototype" bugs.

## The Target Type

```nim
of vkObject:
  entries*: OrderedTable[string, KtgValue]
  parent*: KtgContext  # scope parent chain (nil for standalone objects)
  fieldSpecs*: seq[FieldSpec]  # empty for plain contexts
  typeName*: string  # "" for anonymous, "person" for typed prototypes
```

`KtgContext` becomes a type alias or thin wrapper around the object entries + parent. `KtgPrototype` is deleted.

## Phases

### Phase 1: Add the unified type (additive, no removals)

1. Add `vkObject` to `ValueKind` in `types.nim`
2. Add the fields above to the KtgValue variant
3. Add a `newObject` constructor
4. Make both `context` and `prototype` create `vkObject` values (context: empty fieldSpecs, no typeName; prototype: has fieldSpecs, has typeName)
5. All existing `vkContext` and `vkPrototype` branches still work — nothing removed yet
6. Run tests — everything should pass unchanged

### Phase 2: Migrate consumers one at a time

Each of these is a separate commit. After each, run full test suite.

**a. Equality (`equality.nim`)**
- Merge the `vkContext` and `vkPrototype` branches into one `vkObject` branch
- Structural comparison on `entries` (same as both currently do)

**b. Path navigation (`evaluator.nim: navigatePath`)**
- Merge into one `vkObject` branch: `current = current.entries[seg]`
- Set-path: same — `current.entries[lastSeg] = rhs`

**c. Series operations (`natives.nim`)**
- `words-of`: merge — iterate `entries`
- `size?`/`length?`: merge — `entries.len`
- `copy`: merge — copy `entries` (and `fieldSpecs` if deep)

**d. Deep copy (`natives.nim: deepCopyValue`)**
- Merge — copy entries, fieldSpecs, typeName

**e. Type predicates**
- `context?` and `prototype?` both check `vkObject`
- `context?` could check `fieldSpecs.len == 0` (plain context) or just return true for any object
- `prototype?` could check `fieldSpecs.len > 0` or `typeName != ""`
- Or: both return true for `vkObject` (they're the same thing now)

**f. Object dialect (`object_dialect.nim`)**
- `prototype` creates `vkObject` with fieldSpecs and typeName
- `make` copies a `vkObject`, applies overrides, validates required fields

**g. Evaluator set-word auto-generation**
- `Name: prototype [...]` still auto-generates `name!`, `name?`, `make-name`
- Uses `typeName` field instead of checking `vkPrototype`

**h. Emitter (`lua.nim`)**
- All `vkPrototype` branches become `vkObject` (already emits as tables)
- `vkContext` branches become `vkObject`

### Phase 3: Remove old types

1. Delete `vkContext` and `vkPrototype` from `ValueKind`
2. Delete `KtgContext` type (replace with object entries + parent)
3. Delete `KtgPrototype` type
4. Delete `newContext`, `newPrototype` constructors (replace with `newObject`)
5. Fix all compile errors — each one is a branch that was missed in Phase 2
6. Run full test suite

### Phase 4: Simplify KtgContext

The trickiest part. `KtgContext` currently has:
- `entries: OrderedTable[string, KtgValue]`
- `parent: KtgContext`
- `get(name)` — walks parent chain
- `set(name, val)` — sets in current scope
- `child` — creates child context

These operations need to work on `vkObject` values. Options:
- Make `vkObject` contain a `KtgContext` (keeps parent chain logic intact)
- Inline the parent chain into `vkObject` entries + parent field
- Keep `KtgContext` as an internal implementation detail, not a value kind

**Recommended:** Keep `KtgContext` as the internal scope mechanism. `vkObject` wraps a `KtgContext` plus optional `fieldSpecs` and `typeName`. This is the smallest change — the scope chain still works, prototypes are just contexts with metadata.

```nim
of vkObject:
  ctx*: KtgContext  # scope with entries and parent chain
  fieldSpecs*: seq[FieldSpec]
  typeName*: string
```

## Risk

**High.** This touches every layer. The safest approach:
- Do it on a branch
- Phase 1 is zero-risk (additive)
- Phase 2 is low-risk per commit (one consumer at a time)
- Phase 3 is where breakage happens — compile errors guide you
- Phase 4 is the design decision — how much of KtgContext to keep

## Estimated scope

- Phase 1: ~30 minutes
- Phase 2: ~2 hours (8 consumers, ~15 min each)
- Phase 3: ~1 hour (mechanical deletion + fix compile errors)
- Phase 4: ~30 minutes (if keeping KtgContext as internal wrapper)

Total: half a day of focused work, with tests after every commit.
