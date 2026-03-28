# Object Dialect Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `object` dialect that defines prototype objects with typed fields, default values, lexical `self`, and `make`-based cloning — replacing the manual `context/from` + `set/upvalue` + `@type` incantation for OOP patterns.

**Architecture:** `object` is a native that consumes a dialect block and produces a live prototype (a `context!` with metadata). The dialect parser extracts field specs (name, type, default) and method functions from the block. `make` is extended to clone object contexts with overrides. `self` is a lexical binding in the object's context that methods close over. Auto-type registration makes `ObjectName` available as `object-name!` for type checking.

**Tech Stack:** TypeScript, Bun test runner, existing Kintsugi evaluator infrastructure.

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/evaluator/dialect-object.ts` | Create | Parse the object dialect block, build the prototype context |
| `src/evaluator/natives.ts` | Modify | Register `object` native, extend `make` for context cloning |
| `src/evaluator/evaluator.ts` | Modify | Inject `self` when calling methods via path on objects |
| `src/evaluator/context.ts` | Modify | Add `clone()` method for deep-copying bindings |
| `src/tests/object-dialect.test.ts` | Create | All tests for the object dialect |
| `examples/script-spec.ktg` | Modify | Document the object dialect |

---

## Chunk 1: Context Cloning and `make` Extension

### Task 1: Add `clone()` to KtgContext

**Files:**
- Modify: `src/evaluator/context.ts:3-39`
- Test: `src/tests/object-dialect.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// src/tests/object-dialect.test.ts
import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

describe('make clones context', () => {
  test('clone context with overrides', () => {
    const ev = new Evaluator();
    ev.evalString('p: context [name: "Ray" age: 30]');
    ev.evalString('p2: make p [age: 31]');
    expect(ev.evalString('p2/name')).toEqual({ type: 'string!', value: 'Ray' });
    expect(ev.evalString('p2/age')).toEqual({ type: 'integer!', value: 31 });
  });

  test('clone does not mutate original', () => {
    const ev = new Evaluator();
    ev.evalString('p: context [name: "Ray" age: 30]');
    ev.evalString('p2: make p [age: 31]');
    expect(ev.evalString('p/age')).toEqual({ type: 'integer!', value: 30 });
  });

  test('clone with empty overrides', () => {
    const ev = new Evaluator();
    ev.evalString('p: context [x: 10]');
    ev.evalString('p2: make p []');
    expect(ev.evalString('p2/x')).toEqual({ type: 'integer!', value: 10 });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: FAIL — `make not supported for context!`

- [ ] **Step 3: Add `clone()` method to KtgContext**

In `src/evaluator/context.ts`, add after the `child()` method:

```typescript
clone(): KtgContext {
  const cloned = new KtgContext(this.parent);
  for (const [key, val] of this.bindings) {
    cloned.set(key, val);
  }
  return cloned;
}
```

- [ ] **Step 4: Extend `make` to handle context cloning**

In `src/evaluator/natives.ts:385-399`, replace the `make` native with:

```typescript
native('make', 2, (args, ev, callerCtx) => {
  const [target, spec] = args;

  // make map! [...]
  if (target.type === 'type!' && target.name === 'map!' && spec.type === 'block!') {
    const entries = new Map<string, KtgValue>();
    for (let i = 0; i < spec.values.length - 1; i += 2) {
      const key = spec.values[i];
      const val = spec.values[i + 1];
      const keyStr = key.type === 'set-word!' ? key.name : valueToString(key);
      entries.set(keyStr, val);
    }
    return { type: 'map!', entries };
  }

  // make <context> [overrides]
  if (target.type === 'context!' && spec.type === 'block!') {
    const cloned = target.context.clone();
    ev.evalBlock(spec as KtgBlock, cloned);
    return { type: 'context!', context: cloned };
  }

  const typeName = target.type === 'type!' ? target.name : valueToString(target);
  throw new KtgError('type', `make not supported for ${typeName}`);
});
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: 3 PASS

- [ ] **Step 6: Run full test suite**

Run: `bun test`
Expected: All existing tests still pass.

- [ ] **Step 7: Commit**

```bash
git add src/evaluator/context.ts src/evaluator/natives.ts src/tests/object-dialect.test.ts
git commit -m "feat: extend make to clone contexts with overrides"
```

---

## Chunk 2: Object Dialect Parser

### Task 2: Create the dialect parser

**Files:**
- Create: `src/evaluator/dialect-object.ts`
- Test: `src/tests/object-dialect.test.ts`

The dialect block has three kinds of entries:
1. **Required field:** `name [string!]` — word followed by type block, no `@default`
2. **Defaulted field:** `balance [float!] @default 0.0` — word, type block, `@default`, value
3. **Method:** `greet: function [] [...]` — set-word binding a function

The parser extracts these into a structured config that the `object` native uses to build the prototype.

- [ ] **Step 1: Write the failing test**

```typescript
describe('object dialect', () => {
  test('basic object with fields and methods', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Person: object [
        name [string!]
        age [integer!]
        greet: function [] [
          rejoin ["Hi, I'm " self/name]
        ]
      ]
    `);
    const p = ev.evalString('make Person [name: "Ray" age: 30]');
    expect(p.type).toBe('context!');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: FAIL — `object has no value`

- [ ] **Step 3: Create `src/evaluator/dialect-object.ts`**

```typescript
import { KtgContext } from './context';
import {
  KtgValue, KtgBlock, KtgError, NONE,
} from './values';
import type { Evaluator } from './evaluator';

export interface ObjectFieldSpec {
  name: string;
  type: string;
  defaultValue: KtgValue | null;  // null = required (no default)
}

export interface ObjectSpec {
  fields: ObjectFieldSpec[];
  methods: { name: string; value: KtgValue }[];
}

export function parseObjectDialect(block: KtgBlock): ObjectSpec {
  const fields: ObjectFieldSpec[] = [];
  const methods: { name: string; value: KtgValue }[] = [];
  const values = block.values;
  let i = 0;

  while (i < values.length) {
    const v = values[i];

    // Method: set-word followed by a function value
    if (v.type === 'set-word!') {
      const name = v.name;
      i++;
      // Collect the value (should be the raw function definition block — but it's
      // actually the word 'function' followed by spec and body, which will be
      // evaluated later). We store everything from the set-word onward as-is
      // and let evalBlock handle it.
      methods.push({ name, value: values[i] });
      // We need to skip past the function's spec and body too
      // But since we don't know the shape here, we store a marker and let
      // the object builder evaluate methods in context.
      // Actually: methods are just set-word assignments in the block.
      // We'll handle them by letting evalBlock process the whole block.
      // Remove from methods array — we'll use a different approach.
      methods.pop();
      // Back up — we'll handle methods differently
      i--;
      break;
    }

    // Field: word followed by type block, optionally followed by @default value
    if (v.type === 'word!') {
      const name = v.name;
      i++;
      let type = 'any-type!';
      let defaultValue: KtgValue | null = null;

      // Type block
      if (i < values.length && values[i].type === 'block!') {
        const typeBlock = values[i] as KtgBlock;
        if (typeBlock.values.length > 0 && typeBlock.values[0].type === 'word!') {
          type = (typeBlock.values[0] as any).name;
        }
        i++;
      }

      // @default
      if (i < values.length && values[i].type === 'meta-word!' && (values[i] as any).name === 'default') {
        i++;
        if (i < values.length) {
          defaultValue = values[i];
          i++;
        }
      }

      fields.push({ name, type, defaultValue });
      continue;
    }

    i++;
  }

  return { fields, methods };
}
```

Wait — this approach of separating parsing from evaluation gets complicated because methods are expressions that need evaluation (`function [] [...]`). A cleaner approach: the dialect parser only extracts field specs (names, types, defaults). Everything else (method definitions) is left in the block and evaluated by `evalBlock` after the fields are set up.

Replace the above with this cleaner design:

```typescript
import {
  KtgValue, KtgBlock, KtgError, NONE,
} from './values';

export interface ObjectFieldSpec {
  name: string;
  type: string;
  hasDefault: boolean;
  defaultValue: KtgValue;  // NONE if no default
  optional: boolean;        // from [opt type!]
}

export function parseObjectDialect(block: KtgBlock): {
  fields: ObjectFieldSpec[];
  bodyStart: number;  // index where non-field entries begin
} {
  const fields: ObjectFieldSpec[] = [];
  const values = block.values;
  let i = 0;

  while (i < values.length) {
    const v = values[i];

    // A bare word followed by a type block = field declaration
    if (v.type === 'word!' && i + 1 < values.length && values[i + 1].type === 'block!') {
      const name = (v as any).name;
      const typeBlock = values[i + 1] as KtgBlock;
      let type = 'any-type!';
      let optional = false;

      if (typeBlock.values.length > 0) {
        let ti = 0;
        if (typeBlock.values[ti].type === 'word!' && (typeBlock.values[ti] as any).name === 'opt') {
          optional = true;
          ti++;
        }
        if (ti < typeBlock.values.length && typeBlock.values[ti].type === 'word!') {
          type = (typeBlock.values[ti] as any).name;
        }
      }
      i += 2;

      // Check for @default
      let hasDefault = false;
      let defaultValue: KtgValue = NONE;
      if (i < values.length && values[i].type === 'meta-word!' && (values[i] as any).name === 'default') {
        hasDefault = true;
        i++;
        if (i < values.length) {
          defaultValue = values[i];
          i++;
        }
      }

      fields.push({ name, type, hasDefault, defaultValue, optional });
      continue;
    }

    // Anything else (set-word, etc.) = end of field declarations
    break;
  }

  return { fields, bodyStart: i };
}
```

- [ ] **Step 4: Run tests to verify they still fail**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: Still FAIL — `object` native not yet registered.

- [ ] **Step 5: Commit parser**

```bash
git add src/evaluator/dialect-object.ts
git commit -m "feat: add object dialect parser"
```

---

### Task 3: Register `object` native

**Files:**
- Modify: `src/evaluator/natives.ts`
- Test: `src/tests/object-dialect.test.ts`

The `object` native:
1. Parses the dialect block to extract field specs
2. Builds a prototype context with default values for all fields
3. Evaluates the rest of the block (methods) in that context
4. Binds `self` in the context pointing to the context value itself
5. Auto-registers the `@type` when assigned to a set-word (handled by naming convention)

- [ ] **Step 1: Add more tests**

Add to the `object dialect` describe block:

```typescript
  test('field access on prototype', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Point: object [
        x [integer!] @default 0
        y [integer!] @default 0
      ]
    `);
    expect(ev.evalString('Point/x')).toEqual({ type: 'integer!', value: 0 });
    expect(ev.evalString('Point/y')).toEqual({ type: 'integer!', value: 0 });
  });

  test('make instance with overrides', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Point: object [
        x [integer!] @default 0
        y [integer!] @default 0
      ]
    `);
    ev.evalString('p: make Point [x: 10 y: 20]');
    expect(ev.evalString('p/x')).toEqual({ type: 'integer!', value: 10 });
    expect(ev.evalString('p/y')).toEqual({ type: 'integer!', value: 20 });
  });

  test('mixed required and defaulted fields', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Account: object [
        owner [string!]
        balance [float!] @default 0.0
        active [logic!] @default true
      ]
    `);
    // Required field (owner) must be set; defaulted fields are pre-filled
    ev.evalString('a: make Account [owner: "Ray"]');
    expect(ev.evalString('a/owner')).toEqual({ type: 'string!', value: 'Ray' });
    expect(ev.evalString('a/balance')).toEqual({ type: 'float!', value: 0.0 });
    expect(ev.evalString('a/active')).toEqual({ type: 'logic!', value: true });
  });

  test('mixed fields with override on defaulted', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Account: object [
        owner [string!]
        balance [float!] @default 0.0
        active [logic!] @default true
      ]
    `);
    ev.evalString('a: make Account [owner: "Ray" balance: 100.0]');
    expect(ev.evalString('a/owner')).toEqual({ type: 'string!', value: 'Ray' });
    expect(ev.evalString('a/balance')).toEqual({ type: 'float!', value: 100.0 });
    expect(ev.evalString('a/active')).toEqual({ type: 'logic!', value: true });
  });

  test('mixed fields with methods that use both', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Account: object [
        owner [string!]
        balance [float!] @default 0.0
        deposit: function [amount [float!]] [
          self/balance: self/balance + amount
        ]
        summary: function [] [
          rejoin [self/owner ": $" self/balance]
        ]
      ]
    `);
    ev.evalString('a: make Account [owner: "Ray"]');
    ev.evalString('a/deposit 50.0');
    expect(ev.evalString('a/summary')).toEqual({ type: 'string!', value: 'Ray: $50' });
  });

  test('methods see self', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Person: object [
        name [string!] @default none
        age [integer!] @default 0
        greet: function [] [
          rejoin ["Hi, I'm " self/name]
        ]
      ]
    `);
    ev.evalString('p: make Person [name: "Ray" age: 30]');
    expect(ev.evalString('p/greet')).toEqual({ type: 'string!', value: "Hi, I'm Ray" });
  });

  test('methods can mutate via self', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Counter: object [
        n [integer!] @default 0
        increment: function [] [
          self/n: self/n + 1
        ]
        value: function [] [self/n]
      ]
    `);
    ev.evalString('c: make Counter []');
    ev.evalString('c/increment');
    ev.evalString('c/increment');
    expect(ev.evalString('c/value')).toEqual({ type: 'integer!', value: 2 });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: FAIL — `object has no value`

- [ ] **Step 3: Register the `object` native**

In `src/evaluator/natives.ts`, after the `context` native (line 412), add:

```typescript
  native('object', 1, (args, ev, callerCtx) => {
    const block = args[0];
    if (block.type !== 'block!') throw new KtgError('type', 'object expects a block');

    const { parseObjectDialect } = require('./dialect-object');
    const { fields, bodyStart } = parseObjectDialect(block as KtgBlock);

    // Build prototype context
    const objCtx = new KtgContext(callerCtx);

    // Set field defaults
    for (const field of fields) {
      if (field.hasDefault) {
        // Evaluate default value expressions
        const defaultVal = field.defaultValue.type === 'paren!'
          ? ev.evalBlock(field.defaultValue, callerCtx)
          : field.defaultValue;
        objCtx.set(field.name, defaultVal);
      } else {
        objCtx.set(field.name, NONE);
      }
    }

    // Create the context value so self can reference it
    const objValue: KtgValue = { type: 'context!', context: objCtx };

    // Bind self
    objCtx.set('self', objValue);

    // Evaluate the rest of the block (methods, computed fields) in the object context
    if (bodyStart < (block as KtgBlock).values.length) {
      const methodBlock: KtgBlock = {
        type: 'block!',
        values: (block as KtgBlock).values.slice(bodyStart),
      };
      ev.evalBlock(methodBlock, objCtx);
    }

    // Store field specs as metadata for type checking and make
    (objValue as any).__fields = fields;

    return objValue;
  });
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: PASS for prototype/field tests. Method tests may need `self` injection (Task 4).

- [ ] **Step 5: Run full test suite**

Run: `bun test`
Expected: All existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/evaluator/natives.ts src/evaluator/dialect-object.ts src/tests/object-dialect.test.ts
git commit -m "feat: register object native with dialect parser"
```

---

## Chunk 3: Self Injection and Method Calls

### Task 4: Inject `self` when calling methods via path

**Files:**
- Modify: `src/evaluator/evaluator.ts:310-334`
- Test: `src/tests/object-dialect.test.ts`

When `p/greet` is evaluated and `p` is a context, the evaluator navigates to the `greet` field (a function). Currently (line 330) it calls the function with no knowledge of `p`. We need to update `self` in the function's closure to point to the instance, not the prototype.

The key insight: `self` is already in the method's closure (from the prototype). When we clone via `make`, we need `self` in the clone to point to the clone. This happens naturally if `make` (for contexts with `__fields`) re-binds `self` after cloning.

- [ ] **Step 1: Write the failing test**

```typescript
  test('self refers to instance, not prototype', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Thing: object [
        x [integer!] @default 0
        get-x: function [] [self/x]
      ]
    `);
    ev.evalString('a: make Thing [x: 10]');
    ev.evalString('b: make Thing [x: 20]');
    expect(ev.evalString('a/get-x')).toEqual({ type: 'integer!', value: 10 });
    expect(ev.evalString('b/get-x')).toEqual({ type: 'integer!', value: 20 });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: FAIL — `self` in clone still points to prototype.

- [ ] **Step 3: Update `make` to re-bind `self` on cloned object contexts**

In the `make` native in `src/evaluator/natives.ts`, update the context cloning branch:

```typescript
  // make <context> [overrides]
  if (target.type === 'context!' && spec.type === 'block!') {
    const cloned = target.context.clone();
    const clonedValue: KtgValue = { type: 'context!', context: cloned };

    // Re-bind self if this is an object
    if (cloned.has('self')) {
      cloned.set('self', clonedValue);
    }

    // Copy field metadata if present
    if ((target as any).__fields) {
      (clonedValue as any).__fields = (target as any).__fields;
    }

    ev.evalBlock(spec as KtgBlock, cloned);
    return clonedValue;
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `bun test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/evaluator/natives.ts src/tests/object-dialect.test.ts
git commit -m "feat: re-bind self on cloned object contexts"
```

---

### Task 5: Verify `self` mutation via set-path works

**Files:**
- Test: `src/tests/object-dialect.test.ts`

`self/field: value` mutation already works through the existing set-path mechanism (evaluator.ts:200-216) — `setField` on a context calls `context.set()`. This task just confirms it works end-to-end with the object dialect.

- [ ] **Step 1: Write the tests**

```typescript
  test('mutation via self/field: persists', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Counter: object [
        n [integer!] @default 0
        increment: function [] [self/n: self/n + 1]
        value: function [] [self/n]
      ]
    `);
    ev.evalString('c: make Counter []');
    ev.evalString('c/increment');
    ev.evalString('c/increment');
    ev.evalString('c/increment');
    expect(ev.evalString('c/value')).toEqual({ type: 'integer!', value: 3 });
  });

  test('mutation on one instance does not affect another', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Counter: object [
        n [integer!] @default 0
        increment: function [] [self/n: self/n + 1]
      ]
    `);
    ev.evalString('a: make Counter []');
    ev.evalString('b: make Counter []');
    ev.evalString('a/increment');
    ev.evalString('a/increment');
    ev.evalString('b/increment');
    expect(ev.evalString('a/n')).toEqual({ type: 'integer!', value: 2 });
    expect(ev.evalString('b/n')).toEqual({ type: 'integer!', value: 1 });
  });
```

- [ ] **Step 2: Run tests**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/tests/object-dialect.test.ts
git commit -m "test: verify self mutation on object instances"
```

---

## Chunk 4: Auto-Type Registration

### Task 6: Auto-register `@type` from object definitions

**Files:**
- Modify: `src/evaluator/natives.ts` (object native)
- Test: `src/tests/object-dialect.test.ts`

When `Person: object [name [string!] ...]` is evaluated, we want `person!` to be available as a type for param constraints. The `object` native builds the `@type` rule from field specs and registers it in the caller's context.

Naming convention: `Person` → `person!`, `CardReader` → `card-reader!` (PascalCase → kebab-case with `!`).

However, the `object` native doesn't know the name it's being assigned to — the set-word is handled by the evaluator before the native runs. So auto-registration must use a different mechanism.

**Approach:** The object native stores field specs on the context value. A helper function `objectTypeName` converts PascalCase to kebab-case. The `object` native registers the type eagerly, but it doesn't know the name. Instead, we store the type rule on the object and let the user register it explicitly, OR we add a post-assignment hook.

**Simpler approach:** The object knows its field specs. We store a pre-built `@type` rule on the object. When the user writes `Person: object [...]`, the type `person!` can be registered by convention at the evaluator level when a set-word assigns an object value.

**Simplest approach:** Don't auto-register. The object already works as a type when passed to `make`. For param checking, the user writes `person!: @type [...]` separately, or we provide a `type-of-object` helper. This keeps the object dialect focused.

Actually — since we have `__fields` metadata on the object, we can make `is?` and type checking work by matching context fields against the prototype's fields. When `checkType` encounters a context value and the constraint resolves to another context (the prototype), it compares fields.

**Revised approach:** Skip auto-registration for now. The object's `__fields` metadata enables type checking via a different path — we can check if a context has all the fields of a prototype. This is more useful than name-based type registration because it's structural.

- [ ] **Step 1: Write the failing test**

```typescript
describe('object type checking', () => {
  test('is? checks against prototype', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Person: object [
        name [string!] @default none
        age [integer!] @default 0
      ]
    `);
    ev.evalString('p: make Person [name: "Ray" age: 30]');
    expect(ev.evalString('is? :Person p')).toEqual({ type: 'logic!', value: true });
  });

  test('is? rejects non-matching context', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Person: object [
        name [string!] @default none
        age [integer!] @default 0
      ]
    `);
    ev.evalString('x: context [foo: 1]');
    expect(ev.evalString('is? :Person x')).toEqual({ type: 'logic!', value: false });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: FAIL

- [ ] **Step 3: Extend `is?` / `matchesType` to support prototype-based checking**

In `src/evaluator/type-check.ts`, update `matchesType` to handle when the type name resolves to a context with `__fields`:

```typescript
// In matchesType, after the @type check:
if (resolved && resolved.type === 'context!' && (resolved as any).__fields) {
  if (value.type !== 'context!') return false;
  const fields: ObjectFieldSpec[] = (resolved as any).__fields;
  const ctxVal = (value as any).context as KtgContext;
  for (const field of fields) {
    const fieldVal = ctxVal.get(field.name);
    if (fieldVal === undefined) return false;
    if (fieldVal.type !== 'none!' || !field.optional) {
      if (!matchesTypeCore(fieldVal, field.type) && !matchesType(fieldVal, field.type, ctx, ev)) {
        return false;
      }
    }
  }
  return true;
}
```

Similarly update `checkType`.

Note: `is?` uses a get-word (`:Person`) to get the prototype value without calling it. The type checking functions need to handle when the constraint resolves to a context with `__fields` instead of a `type!` value.

This requires modifying how `is?` works — it currently expects a `type!` value. We need to check whether `is?` can accept a context-as-prototype for type checking.

Check the `is?` implementation first. If it only accepts `type!`, we'll need to adjust it.

- [ ] **Step 4: Check and modify `is?` native if needed**

Look at the `is?` native in `src/evaluator/natives.ts`. If it expects a `type!` value as the first arg, it won't accept a context prototype directly. Extend it to handle context prototypes with `__fields`.

- [ ] **Step 5: Run tests**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: PASS

- [ ] **Step 6: Run full test suite**

Run: `bun test`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/evaluator/type-check.ts src/evaluator/natives.ts src/tests/object-dialect.test.ts
git commit -m "feat: prototype-based type checking for objects"
```

---

## Chunk 5: Card Reader End-to-End and Spec Documentation

### Task 7: End-to-end card reader test

**Files:**
- Test: `src/tests/object-dialect.test.ts`

- [ ] **Step 1: Write the integration test**

```typescript
describe('object dialect — card reader', () => {
  test('full card reader workflow', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Card: object [
        cardholder-name [string!]
        number [string!]
        balance [float!] @default 0.0
        ounces-poured [float!] @default 0.0
      ]

      Reader: object [
        events [block!] @default []
        current-card [opt context!] @default none

        insert-card: function [card] [
          append self/events "inserted"
          self/current-card: card
        ]

        remove-card: function [] [
          append self/events "removed"
          self/current-card: none
        ]
      ]

      my-card: make Card [cardholder-name: "Ray Perry" number: "5555"]
      my-reader: make Reader []
      my-reader/insert-card my-card
      my-reader/remove-card
    `);
    expect(ev.evalString('length? my-reader/events')).toEqual({ type: 'integer!', value: 2 });
    expect(ev.evalString('my-reader/current-card')).toEqual({ type: 'none!' });
  });

  test('card reader card has required fields', () => {
    const ev = new Evaluator();
    ev.evalString(`
      Card: object [
        cardholder-name [string!]
        number [string!]
        balance [float!] @default 0.0
      ]
      my-card: make Card [cardholder-name: "Ray" number: "1234"]
    `);
    expect(ev.evalString('my-card/cardholder-name')).toEqual({ type: 'string!', value: 'Ray' });
    expect(ev.evalString('my-card/number')).toEqual({ type: 'string!', value: '1234' });
    expect(ev.evalString('my-card/balance')).toEqual({ type: 'float!', value: 0.0 });
  });
});
```

- [ ] **Step 2: Run test**

Run: `bun test src/tests/object-dialect.test.ts`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/tests/object-dialect.test.ts
git commit -m "test: end-to-end card reader with object dialect"
```

---

### Task 8: Document in script-spec.ktg

**Files:**
- Modify: `examples/script-spec.ktg`

- [ ] **Step 1: Add object dialect section**

In `examples/script-spec.ktg`, before the LIFECYCLE HOOKS section, add:

```kintsugi
; --- Object dialect ---
; object defines a prototype with typed fields, defaults,
; and methods. make stamps instances from prototypes.
; Methods access the instance via self (lexically bound).
;
; Field syntax:
;   name [type!]                — required (must be set in make)
;   name [type!] @default val   — defaulted (pre-filled)
;   name [opt type!] @default none — optional (type or none)
;
; Everything after field declarations is evaluated as the
; prototype's body — typically method definitions.

Counter: object [
  n [integer!] @default 0
  increment: function [] [self/n: self/n + 1]
  value: function [] [self/n]
]

c: make Counter []
c/increment
c/increment
print c/value                           ; 2

; Required fields must be set in make:
Person: object [
  name [string!]
  age [integer!]
  greet: function [] [
    rejoin ["Hi, I'm " self/name " age " self/age]
  ]
  birthday: function [] [
    self/age: self/age + 1
  ]
]

p: make Person [name: "Ray" age: 30]
print p/greet                           ; Hi, I'm Ray age 30
p/birthday
print p/age                             ; 31

; Clone from an instance
p2: make p [age: 25]
print p2/name                           ; Ray
print p2/age                            ; 25
print p/age                             ; 31 (original unchanged)

; --- Mixed required and defaulted fields ---
; Required fields (no @default) must be provided in make.
; Defaulted fields are pre-filled and can be overridden.

Account: object [
  owner [string!]
  currency [string!] @default "USD"
  balance [float!] @default 0.0
  deposit: function [amount [float!]] [
    self/balance: self/balance + amount
  ]
  summary: function [] [
    rejoin [self/owner ": " self/currency " " self/balance]
  ]
]

a: make Account [owner: "Ray"]
a/deposit 100.0
print a/summary                         ; Ray: USD 100.0
print a/currency                        ; USD

; Override a default at creation time
b: make Account [owner: "Jo" currency: "EUR" balance: 50.0]
print b/summary                         ; Jo: EUR 50.0
```

- [ ] **Step 2: Run full test suite**

Run: `bun test`
Expected: All tests pass (spec-examples test file may need update if it validates examples).

- [ ] **Step 3: Commit**

```bash
git add examples/script-spec.ktg
git commit -m "docs: add object dialect to script-spec"
```

---

## Summary

| Chunk | Tasks | What it delivers |
|-------|-------|-----------------|
| 1 | Context cloning, `make` extension | `make context [overrides]` works |
| 2 | Dialect parser, `object` native | `object [...]` creates prototypes with fields and methods |
| 3 | `self` injection on clone | `self` refers to the instance, mutation works |
| 4 | Type checking via prototype | `is? :Person p` structural matching |
| 5 | Integration test, docs | Card reader works, spec updated |
