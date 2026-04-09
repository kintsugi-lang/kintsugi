# Evaluator Next Phases Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement stdlib, loop refinements, object, error handling, and block parsing for Kintsugi's evaluator.

**Architecture:** Five sequential builds on the existing evaluator. Each adds natives to `src/evaluator/natives.ts` or new files to `src/evaluator/`. Parse is the largest piece — a new `src/evaluator/parse.ts` file implementing a recursive descent interpreter over rule blocks.

**Tech Stack:** TypeScript, Bun test runner, `@/` and `@types` path aliases.

**Spec:** `docs/superpowers/specs/2026-03-19-evaluator-next-phases-design.md`

**Note:** String parsing is stubbed (throws "not yet implemented").

---

## Chunk 1: Stdlib & Loop Refinements

### Task 1: `unless`, `all`, `any` natives

**Files:**
- Modify: `src/evaluator/natives.ts`
- Create: `src/tests/stdlib.test.ts`

- [ ] **Step 1: Write failing tests**

Create `src/tests/stdlib.test.ts`:

```typescript
import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('unless', () => {
  test('evaluates block when condition is falsy', () => {
    expect(eval_('unless false [42]')).toEqual({ type: 'integer!', value: 42 });
  });

  test('returns none when condition is truthy', () => {
    expect(eval_('unless true [42]')).toEqual({ type: 'none!' });
  });

  test('none is falsy', () => {
    expect(eval_('unless none [42]')).toEqual({ type: 'integer!', value: 42 });
  });
});

describe('all', () => {
  test('returns last value if all truthy', () => {
    expect(eval_('all [1 2 3]')).toEqual({ type: 'integer!', value: 3 });
  });

  test('returns first falsy value', () => {
    expect(eval_('all [1 false 3]')).toEqual({ type: 'logic!', value: false });
  });

  test('short-circuits on false', () => {
    const ev = new Evaluator();
    ev.evalString('x: 0');
    ev.evalString('all [false (x: 1)]');
    expect(ev.evalString('x')).toEqual({ type: 'integer!', value: 0 });
  });

  test('evaluates expressions', () => {
    expect(eval_('all [1 = 1 2 = 2]')).toEqual({ type: 'logic!', value: true });
  });
});

describe('any', () => {
  test('returns first truthy value', () => {
    expect(eval_('any [false 42 99]')).toEqual({ type: 'integer!', value: 42 });
  });

  test('returns none if all falsy', () => {
    expect(eval_('any [false none false]')).toEqual({ type: 'none!' });
  });

  test('short-circuits on truthy', () => {
    const ev = new Evaluator();
    ev.evalString('x: 0');
    ev.evalString('any [42 (x: 1)]');
    expect(ev.evalString('x')).toEqual({ type: 'integer!', value: 0 });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bun test src/tests/stdlib.test.ts`

- [ ] **Step 3: Implement `unless`, `all`, `any`**

In `src/evaluator/natives.ts`, after the `not` native (~line 77):

```typescript
  native('unless', 2, (args, ev, callerCtx) => {
    const [cond, block] = args;
    if (block.type !== 'block!') throw new KtgError('type', 'unless expects a block');
    if (!isTruthy(cond)) return ev.evalBlock(block, callerCtx);
    return NONE;
  });

  native('all', 1, (args, ev, callerCtx) => {
    const block = args[0];
    if (block.type !== 'block!') throw new KtgError('type', 'all expects a block');
    let result: KtgValue = NONE;
    const values = block.values;
    let pos = 0;
    while (pos < values.length) {
      [result, pos] = ev.evalNext(values, pos, callerCtx);
      while (pos < values.length && ev.nextIsInfix(values, pos, callerCtx)) {
        [result, pos] = ev.applyInfix(result, values, pos, callerCtx);
      }
      if (!isTruthy(result)) return result;
    }
    return result;
  });

  native('any', 1, (args, ev, callerCtx) => {
    const block = args[0];
    if (block.type !== 'block!') throw new KtgError('type', 'any expects a block');
    let result: KtgValue = NONE;
    const values = block.values;
    let pos = 0;
    while (pos < values.length) {
      [result, pos] = ev.evalNext(values, pos, callerCtx);
      while (pos < values.length && ev.nextIsInfix(values, pos, callerCtx)) {
        [result, pos] = ev.applyInfix(result, values, pos, callerCtx);
      }
      if (isTruthy(result)) return result;
    }
    return NONE;
  });
```

- [ ] **Step 4: Run tests**

Run: `bun test src/tests/stdlib.test.ts`

- [ ] **Step 5: Run full suite**

Run: `bun test`

---

### Task 2: `apply` native and type predicates

**Files:**
- Modify: `src/evaluator/natives.ts`
- Modify: `src/tests/stdlib.test.ts`

- [ ] **Step 1: Add failing tests**

Append to `src/tests/stdlib.test.ts`:

```typescript
describe('apply', () => {
  test('calls function with block args', () => {
    expect(eval_('add: function [a b] [a + b] apply :add [3 4]')).toEqual({ type: 'integer!', value: 7 });
  });

  test('works with natives', () => {
    const ev = new Evaluator();
    ev.evalString('apply :print [42]');
    expect(ev.output).toEqual(['42']);
  });
});

describe('type predicates', () => {
  test('none?', () => {
    expect(eval_('none? none')).toEqual({ type: 'logic!', value: true });
    expect(eval_('none? 42')).toEqual({ type: 'logic!', value: false });
  });

  test('integer?', () => {
    expect(eval_('integer? 42')).toEqual({ type: 'logic!', value: true });
    expect(eval_('integer? "hi"')).toEqual({ type: 'logic!', value: false });
  });

  test('float?', () => {
    expect(eval_('float? 3.14')).toEqual({ type: 'logic!', value: true });
  });

  test('string?', () => {
    expect(eval_('string? "hi"')).toEqual({ type: 'logic!', value: true });
  });

  test('logic?', () => {
    expect(eval_('logic? true')).toEqual({ type: 'logic!', value: true });
  });

  test('block?', () => {
    expect(eval_('block? [1 2]')).toEqual({ type: 'logic!', value: true });
  });

  test('function? matches user functions and natives', () => {
    expect(eval_('function? :print')).toEqual({ type: 'logic!', value: true });
    expect(eval_('function? 42')).toEqual({ type: 'logic!', value: false });
  });
});
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bun test src/tests/stdlib.test.ts`

- [ ] **Step 3: Implement `apply` and type predicates**

Add `isCallable` to the import at the top of `src/evaluator/natives.ts`:

```typescript
import {
  KtgValue, KtgBlock, KtgNative, KtgOp,
  NONE, TRUE, FALSE,
  isTruthy, typeOf, valueToString, numVal, isNumeric, isCallable,
  KtgError, BreakSignal, ReturnSignal,
} from './values';
```

After the `set` native in `src/evaluator/natives.ts`:

```typescript
  native('apply', 2, (args, ev, callerCtx) => {
    const [fn, argBlock] = args;
    if (!isCallable(fn)) throw new KtgError('type', 'apply expects a function');
    if (argBlock.type !== 'block!') throw new KtgError('type', 'apply expects a block of arguments');
    const [result] = ev.callCallable(fn, argBlock.values, 0, callerCtx);
    return result;
  });
```

At the end of `registerNatives`, before the closing `}`:

```typescript
  // === Type Predicates ===

  // function? matches both user-defined and native functions
  native('function?', 1, (args) => ({
    type: 'logic!',
    value: args[0].type === 'function!' || args[0].type === 'native!',
  }));

  const typePredicates: [string, string][] = [
    ['none?', 'none!'], ['integer?', 'integer!'], ['float?', 'float!'],
    ['string?', 'string!'], ['logic?', 'logic!'], ['char?', 'char!'],
    ['block?', 'block!'], ['object?', 'object!'],
    ['pair?', 'pair!'], ['tuple?', 'tuple!'], ['date?', 'date!'],
    ['time?', 'time!'], ['binary?', 'binary!'], ['file?', 'file!'],
    ['url?', 'url!'], ['email?', 'email!'], ['word?', 'word!'],
    ['map?', 'map!'],
  ];

  for (const [name, typeName] of typePredicates) {
    native(name, 1, (args) => ({ type: 'logic!', value: args[0].type === typeName }));
  }
```

- [ ] **Step 4: Run tests**

Run: `bun test src/tests/stdlib.test.ts`

- [ ] **Step 5: Run full suite**

Run: `bun test`

---

### Task 3: Wire loop refinements — `loop/fold`, `loop/partition`

**Files:**
- Modify: `src/evaluator/natives.ts` (update `loop` native)
- Modify: `src/evaluator/dialect-loop.ts` (replace `executeLoop`)
- Modify: `src/tests/loop.test.ts`

- [ ] **Step 1: Add failing tests**

Append to `src/tests/loop.test.ts`:

```typescript
describe('loop/fold', () => {
  test('sum 1 to 10', () => {
    expect(eval_('loop/fold [for [acc n] from 1 to 10 [acc + n]]'))
      .toEqual({ type: 'integer!', value: 55 });
  });

  test('fold over series', () => {
    expect(eval_('loop/fold [for [acc x] in [1 2 3 4] [acc + x]]'))
      .toEqual({ type: 'integer!', value: 10 });
  });
});

describe('loop/partition', () => {
  test('split evens and odds', () => {
    const ev = new Evaluator();
    ev.evalString('set [evens odds] loop/partition [for [x] from 1 to 8 [even? x]]');
    const evens = ev.evalString('evens');
    const odds = ev.evalString('odds');
    expect(evens).toEqual({ type: 'block!', values: [
      { type: 'integer!', value: 2 }, { type: 'integer!', value: 4 },
      { type: 'integer!', value: 6 }, { type: 'integer!', value: 8 },
    ]});
    expect(odds).toEqual({ type: 'block!', values: [
      { type: 'integer!', value: 1 }, { type: 'integer!', value: 3 },
      { type: 'integer!', value: 5 }, { type: 'integer!', value: 7 },
    ]});
  });
});
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bun test src/tests/loop.test.ts`

- [ ] **Step 3: Update `loop` native to forward refinements**

In `src/evaluator/natives.ts`, replace the `loop` native:

```typescript
  native('loop', 1, (args, ev, callerCtx, refinements) => {
    const [block] = args;
    if (block.type !== 'block!') throw new KtgError('type', 'loop expects a block');

    let loopRefinement: 'none' | 'collect' | 'fold' | 'partition' = 'none';
    if (refinements.includes('collect')) loopRefinement = 'collect';
    if (refinements.includes('fold')) loopRefinement = 'fold';
    if (refinements.includes('partition')) loopRefinement = 'partition';

    const firstVal = block.values[0];
    if (firstVal && firstVal.type === 'word!' && (firstVal.name === 'for' || firstVal.name === 'from')) {
      const { evalLoop } = require('./dialect-loop');
      return evalLoop(block, loopRefinement, ev, callerCtx);
    }
    try {
      while (true) {
        ev.evalBlock(block, callerCtx);
      }
    } catch (e) {
      if (e instanceof BreakSignal) return e.value;
      throw e;
    }
  });
```

- [ ] **Step 4: Replace `executeLoop` in `dialect-loop.ts`**

Replace the entire `executeLoop` function in `src/evaluator/dialect-loop.ts`:

```typescript
function executeLoop(
  config: LoopConfig,
  refinement: LoopRefinement,
  evaluator: Evaluator,
  parentCtx: KtgContext,
): KtgValue {
  const collected: KtgValue[] = [];
  const truthyBucket: KtgValue[] = [];
  const falsyBucket: KtgValue[] = [];
  let accumulator: KtgValue | null = null;
  let isFirstIteration = true;

  const iterate = (values: KtgValue[][]): void => {
    for (const tuple of values) {
      // Bind loop variables
      for (let j = 0; j < config.vars.length; j++) {
        parentCtx.set(config.vars[j], tuple[j] ?? NONE);
      }

      // Fold: first iteration skips body, inits accumulator
      if (refinement === 'fold' && isFirstIteration) {
        isFirstIteration = false;
        accumulator = tuple[0] ?? NONE;
        continue;
      }

      // Fold: bind accumulator to first var
      if (refinement === 'fold' && accumulator !== null) {
        parentCtx.set(config.vars[0], accumulator);
      }

      // Check guard
      if (config.guard) {
        const guardResult = evaluator.evalBlock(config.guard, parentCtx);
        const { isTruthy } = require('./values');
        if (!isTruthy(guardResult)) continue;
      }

      // Execute body
      let result: KtgValue;
      if (config.body.values.length > 0) {
        result = evaluator.evalBlock(config.body, parentCtx);
      } else {
        result = tuple[0] ?? NONE;
      }

      if (refinement === 'collect') {
        collected.push(result);
      } else if (refinement === 'fold') {
        accumulator = result;
      } else if (refinement === 'partition') {
        const { isTruthy } = require('./values');
        const iterValue = tuple[0] ?? NONE;
        if (isTruthy(result)) {
          truthyBucket.push(iterValue);
        } else {
          falsyBucket.push(iterValue);
        }
      }
    }
  };

  try {
    if (config.source === 'range') {
      const tuples: KtgValue[][] = [];
      if (config.step > 0) {
        for (let n = config.from; n <= config.to; n += config.step) {
          tuples.push([{ type: 'integer!', value: n }]);
        }
      } else {
        for (let n = config.from; n >= config.to; n += config.step) {
          tuples.push([{ type: 'integer!', value: n }]);
        }
      }
      iterate(tuples);
    } else if (config.source === 'series' && config.series) {
      const tuples: KtgValue[][] = [];
      const items = config.series.values;
      const varCount = config.vars.length;
      for (let i = 0; i < items.length; i += varCount) {
        const tuple: KtgValue[] = [];
        for (let j = 0; j < varCount; j++) {
          tuple.push(items[i + j] ?? NONE);
        }
        tuples.push(tuple);
      }
      iterate(tuples);
    }
  } catch (e) {
    if (e instanceof BreakSignal) {
      if (refinement === 'collect') return { type: 'block!', values: collected };
      if (refinement === 'fold') return accumulator ?? NONE;
      if (refinement === 'partition') return { type: 'block!', values: [
        { type: 'block!', values: truthyBucket },
        { type: 'block!', values: falsyBucket },
      ]};
      return e.value;
    }
    throw e;
  }

  if (refinement === 'collect') return { type: 'block!', values: collected };
  if (refinement === 'fold') return accumulator ?? NONE;
  if (refinement === 'partition') return { type: 'block!', values: [
    { type: 'block!', values: truthyBucket },
    { type: 'block!', values: falsyBucket },
  ]};
  return NONE;
}
```

- [ ] **Step 5: Run tests**

Run: `bun test src/tests/loop.test.ts`

- [ ] **Step 6: Run full suite and commit**

Run: `bun test`

```
feat: add stdlib (unless, all, any, apply, type predicates) and loop/fold, loop/partition
```

---

## Chunk 2: Object, Native Refinement Args, & Error Handling

### Task 4: `object` native

**Files:**
- Modify: `src/evaluator/natives.ts`
- Create: `src/tests/object.test.ts`

- [ ] **Step 1: Write failing tests**

Create `src/tests/object.test.ts`:

```typescript
import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('object', () => {
  test('create and access fields', () => {
    const ev = new Evaluator();
    ev.evalString('point: object [x: 10 y: 20]');
    expect(ev.evalString('point/x')).toEqual({ type: 'integer!', value: 10 });
    expect(ev.evalString('point/y')).toEqual({ type: 'integer!', value: 20 });
  });

  test('set-path assignment', () => {
    const ev = new Evaluator();
    ev.evalString('point: object [x: 10 y: 20]');
    ev.evalString('point/x: 30');
    expect(ev.evalString('point/x')).toEqual({ type: 'integer!', value: 30 });
  });

  test('object with computed values', () => {
    const ev = new Evaluator();
    ev.evalString('p: object [x: 2 + 3 y: x * 2]');
    expect(ev.evalString('p/x')).toEqual({ type: 'integer!', value: 5 });
    expect(ev.evalString('p/y')).toEqual({ type: 'integer!', value: 10 });
  });

  test('type? returns object!', () => {
    const ev = new Evaluator();
    ev.evalString('p: object [x: 1]');
    expect(ev.evalString('type? p')).toEqual({ type: 'type!', name: 'object!' });
  });
});
```

- [ ] **Step 2: Run tests, verify failure, implement**

In `src/evaluator/natives.ts`, after the `make` native:

```typescript
  native('object', 1, (args, ev, callerCtx) => {
    const block = args[0];
    if (block.type !== 'block!') throw new KtgError('type', 'object expects a block');
    const objCtx = new KtgContext(callerCtx);
    ev.evalBlock(block, objCtx);
    return { type: 'object!', context: objCtx };
  });
```

- [ ] **Step 3: Run tests**

Run: `bun test src/tests/object.test.ts && bun test`

---

### Task 5: Native refinement args infrastructure

**Problem:** Refinements on natives (like `try/handle`) need to consume extra arguments. Currently `KtgNative` has a fixed `arity` and refinements are just string tags — they can't add args.

**Solution:** Add an optional `refinementArgs` map to `KtgNative`. The evaluator checks active refinements and consumes extra args for each one.

**Files:**
- Modify: `src/evaluator/values.ts` (update `KtgNative` type)
- Modify: `src/evaluator/evaluator.ts` (update `callCallable` for natives)
- Modify: `src/evaluator/natives.ts` (update `native` helper, update `round` registration)
- Test: `src/tests/evaluator.test.ts` (verify `round/down` still works)

- [ ] **Step 1: Update `KtgNative` type**

In `src/evaluator/values.ts`, update the `KtgNative` type:

```typescript
export type KtgNative = {
  type: 'native!';
  name: string;
  arity: number;
  refinementArgs?: Record<string, number>;  // refinement name → extra arg count
  fn: NativeFn;
};
```

- [ ] **Step 2: Update `callCallable` in `evaluator.ts`**

In `src/evaluator/evaluator.ts`, replace the native branch of `callCallable`:

```typescript
    if (fn.type === 'native!') {
      const args: KtgValue[] = [];
      // Consume base arity args
      for (let i = 0; i < fn.arity; i++) {
        if (pos >= values.length) {
          throw new KtgError('args', `${fn.name} expects ${fn.arity} argument(s), got ${i}`);
        }
        let [arg, nextPos] = this.evalNext(values, pos, ctx);
        while (nextPos < values.length && this.nextIsInfix(values, nextPos, ctx)) {
          [arg, nextPos] = this.applyInfix(arg, values, nextPos, ctx);
        }
        args.push(arg);
        pos = nextPos;
      }
      // Consume extra args for active refinements
      const activeRefinements = refinements ?? [];
      if (fn.refinementArgs) {
        for (const ref of activeRefinements) {
          const extraCount = fn.refinementArgs[ref] ?? 0;
          for (let i = 0; i < extraCount; i++) {
            if (pos >= values.length) {
              throw new KtgError('args', `${fn.name}/${ref} expects ${extraCount} extra argument(s)`);
            }
            let [arg, nextPos] = this.evalNext(values, pos, ctx);
            while (nextPos < values.length && this.nextIsInfix(values, nextPos, ctx)) {
              [arg, nextPos] = this.applyInfix(arg, values, nextPos, ctx);
            }
            args.push(arg);
            pos = nextPos;
          }
        }
      }
      return [fn.fn(args, this, ctx, activeRefinements), pos];
    }
```

- [ ] **Step 3: Update `native` helper in `natives.ts`**

Update the `native` helper to accept optional refinement args:

```typescript
  const native = (
    name: string,
    arity: number,
    fn: (args: KtgValue[], ev: Evaluator, callerCtx: KtgContext, refinements: string[]) => KtgValue,
    refinementArgs?: Record<string, number>,
  ) => {
    ctx.set(name, { type: 'native!', name, arity, fn, refinementArgs } as KtgNative);
  };
```

- [ ] **Step 4: Run full suite to verify nothing broke**

Run: `bun test`
Expected: All tests pass (round/down, loop/collect, loop/fold, loop/partition all still work since they don't declare refinementArgs — the extra args map is optional)

---

### Task 6: Error handling — `error`, `try`, `try/handle`

**Files:**
- Modify: `src/evaluator/values.ts` (move `NONE` above `KtgError`, add `data` field)
- Modify: `src/evaluator/natives.ts`
- Create: `src/tests/errors.test.ts`

- [ ] **Step 1: Write failing tests**

Create `src/tests/errors.test.ts`:

```typescript
import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

describe('error and try', () => {
  test('try success result', () => {
    const ev = new Evaluator();
    ev.evalString('result: try [10 + 5]');
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: true });
    expect(ev.evalString("select result 'value")).toEqual({ type: 'integer!', value: 15 });
    expect(ev.evalString("select result 'kind")).toEqual({ type: 'none!' });
    expect(ev.evalString("select result 'message")).toEqual({ type: 'none!' });
    expect(ev.evalString("select result 'data")).toEqual({ type: 'none!' });
  });

  test('try catches division by zero', () => {
    const ev = new Evaluator();
    ev.evalString('result: try [10 / 0]');
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: false });
    expect(ev.evalString("select result 'value")).toEqual({ type: 'none!' });
  });

  test('try catches error with kind + message', () => {
    const ev = new Evaluator();
    ev.evalString("result: try [error 'test-error \"oops\" none]");
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: false });
    expect(ev.evalString("select result 'kind")).toEqual({ type: 'lit-word!', name: 'test-error' });
    expect(ev.evalString("select result 'message")).toEqual({ type: 'string!', value: 'oops' });
  });

  test('try catches error with data', () => {
    const ev = new Evaluator();
    ev.evalString("result: try [error 'bad \"msg\" [x: 1]]");
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: false });
    const data = ev.evalString("select result 'data");
    expect(data.type).toBe('block!');
  });

  test('error with kind only (message and data are none)', () => {
    const ev = new Evaluator();
    ev.evalString("result: try [error 'fail none none]");
    expect(ev.evalString("select result 'kind")).toEqual({ type: 'lit-word!', name: 'fail' });
    expect(ev.evalString("select result 'message")).toEqual({ type: 'none!' });
  });
});

describe('try/handle', () => {
  test('handler receives error info and returns value', () => {
    const ev = new Evaluator();
    ev.evalString("handler: function [kind msg data] [42]");
    ev.evalString("result: try/handle [error 'bad \"oops\" none] :handler");
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: false });
    expect(ev.evalString("select result 'value")).toEqual({ type: 'integer!', value: 42 });
  });

  test('handler not called on success', () => {
    const ev = new Evaluator();
    ev.evalString("handler: function [kind msg data] [99]");
    ev.evalString('result: try/handle [10 + 5] :handler');
    expect(ev.evalString("select result 'ok")).toEqual({ type: 'logic!', value: true });
    expect(ev.evalString("select result 'value")).toEqual({ type: 'integer!', value: 15 });
  });

  test('inline handler function', () => {
    const ev = new Evaluator();
    ev.evalString("result: try/handle [error 'fail \"boom\" none] function [kind msg data] [msg]");
    expect(ev.evalString("select result 'value")).toEqual({ type: 'string!', value: 'boom' });
  });
});
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bun test src/tests/errors.test.ts`

- [ ] **Step 3: Update `KtgError` in `values.ts`**

In `src/evaluator/values.ts`, move the `NONE` constant to just before the `KtgError` class. Then update `KtgError`:

```typescript
export const NONE: KtgNone = { type: 'none!' };

export class KtgError extends Error {
  public data: KtgValue;
  constructor(
    public errorName: string,
    message: string,
    data?: KtgValue,
  ) {
    super(message);
    this.name = 'KtgError';
    this.data = data ?? NONE;
  }
}
```

Remove the duplicate `NONE` from its old location (it was defined later in the file with `TRUE` and `FALSE`). Keep `TRUE` and `FALSE` where they are.

- [ ] **Step 4: Implement `error`, `try`, `try/handle` natives**

In `src/evaluator/natives.ts`, add after the `function` native:

```typescript
  // === Group I: Error Handling ===

  native('error', 3, (args) => {
    const [kindVal, messageVal, dataVal] = args;
    if (kindVal.type !== 'lit-word!') throw new KtgError('type', 'error expects a lit-word as kind');
    const message = messageVal.type === 'string!' ? messageVal.value : '';
    throw new KtgError(kindVal.name, message, dataVal);
  });

  native('try', 1, (args, ev, callerCtx, refinements) => {
    const block = args[0];
    if (block.type !== 'block!') throw new KtgError('type', 'try expects a block');

    const hasHandler = refinements.includes('handle');
    // When /handle is active, args[1] is the handler (consumed via refinementArgs)
    const handler = hasHandler ? args[1] : null;

    try {
      const value = ev.evalBlock(block, callerCtx);
      return makeResult(true, value, NONE, NONE, NONE);
    } catch (e) {
      if (e instanceof KtgError) {
        const kind: KtgValue = { type: 'lit-word!', name: e.errorName };
        const message: KtgValue = e.message ? { type: 'string!', value: e.message } : NONE;
        const data: KtgValue = e.data ?? NONE;

        let handlerValue: KtgValue = NONE;
        if (handler && isCallable(handler)) {
          const handlerArgs: KtgValue[] = [kind, message, data];
          const [result] = ev.callCallable(handler, handlerArgs, 0, callerCtx);
          handlerValue = result;
        }

        return makeResult(false, handlerValue, kind, message, data);
      }
      throw e;
    }
  }, { handle: 1 });  // /handle refinement consumes 1 extra arg
```

Add `makeResult` as a private function at the bottom of `natives.ts` (outside `registerNatives`):

```typescript
function makeResult(ok: boolean, value: KtgValue, kind: KtgValue, message: KtgValue, data: KtgValue): KtgBlock {
  return {
    type: 'block!',
    values: [
      { type: 'set-word!', name: 'ok' }, { type: 'logic!', value: ok },
      { type: 'set-word!', name: 'value' }, value,
      { type: 'set-word!', name: 'kind' }, kind,
      { type: 'set-word!', name: 'message' }, message,
      { type: 'set-word!', name: 'data' }, data,
    ],
  };
}
```

Add `KtgBlock` to the `makeResult` function's imports if needed — it's already imported at the top.

- [ ] **Step 5: Run tests**

Run: `bun test src/tests/errors.test.ts`

- [ ] **Step 6: Run full suite and commit**

Run: `bun test`

```
feat: add object native and error handling (error, try with result! blocks)
```

---

## Chunk 3: Parse Dialect (Block Parsing)

### Task 6: Parse engine

**Files:**
- Create: `src/evaluator/parse.ts`
- Modify: `src/evaluator/natives.ts` (register `parse` and `is?`)
- Create: `src/tests/parse.test.ts`

**Key design decisions:**
- Parse walks the rule block as data — keywords like `some`, `any` are recognized by name, not looked up as native words.
- Integer literals in rules: when encountered as the target of `to`/`thru` or inside `some`/`any`/`not`/`ahead`/`opt`, they match literally. Repeat-count interpretation (`N rule`, `N M rule`) only happens in sequence context (top-level of a rule sequence, not as a sub-rule target).
- `collect`/`keep` uses a stack passed through function args, not context pollution.
- `fail` is a parse keyword — it returns `null` to signal failure. It cannot be used inside `(...)` parens (parens evaluate Kintsugi expressions, not parse keywords).
- Extraction via set-word binds into the caller's context.

- [ ] **Step 1: Write failing tests**

Create `src/tests/parse.test.ts`:

```typescript
import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('parse block — basic matching', () => {
  test('empty rule matches empty block', () => {
    expect(eval_('parse [] []')).toEqual({ type: 'logic!', value: true });
  });

  test('type match', () => {
    expect(eval_('parse [42] [integer!]')).toEqual({ type: 'logic!', value: true });
  });

  test('type mismatch fails', () => {
    expect(eval_('parse [42] [string!]')).toEqual({ type: 'logic!', value: false });
  });

  test('sequence of types', () => {
    expect(eval_('parse [1 "a"] [integer! string!]')).toEqual({ type: 'logic!', value: true });
  });

  test('incomplete match fails', () => {
    expect(eval_('parse [1 2] [integer!]')).toEqual({ type: 'logic!', value: false });
  });

  test('lit-word matches word', () => {
    expect(eval_("parse [name] ['name]")).toEqual({ type: 'logic!', value: true });
  });

  test('skip matches any value', () => {
    expect(eval_('parse [42] [skip]')).toEqual({ type: 'logic!', value: true });
  });

  test('end matches at end', () => {
    expect(eval_('parse [] [end]')).toEqual({ type: 'logic!', value: true });
  });

  test('end fails if not at end', () => {
    expect(eval_('parse [1] [end]')).toEqual({ type: 'logic!', value: false });
  });
});

describe('parse block — repetition', () => {
  test('some matches 1+', () => {
    expect(eval_('parse [1 2 3] [some integer!]')).toEqual({ type: 'logic!', value: true });
  });

  test('some fails on zero', () => {
    expect(eval_('parse ["a"] [some integer!]')).toEqual({ type: 'logic!', value: false });
  });

  test('any matches 0+', () => {
    expect(eval_('parse [] [any integer!]')).toEqual({ type: 'logic!', value: true });
    expect(eval_('parse [1 2 3] [any integer!]')).toEqual({ type: 'logic!', value: true });
  });

  test('opt matches 0 or 1', () => {
    expect(eval_('parse [1] [opt integer! end]')).toEqual({ type: 'logic!', value: true });
    expect(eval_('parse [] [opt integer! end]')).toEqual({ type: 'logic!', value: true });
  });

  test('exact count', () => {
    expect(eval_('parse [1 2 3] [3 integer!]')).toEqual({ type: 'logic!', value: true });
    expect(eval_('parse [1 2] [3 integer!]')).toEqual({ type: 'logic!', value: false });
  });
});

describe('parse block — alternatives', () => {
  test('pipe tries alternatives', () => {
    expect(eval_('parse [1] [integer! | string!]')).toEqual({ type: 'logic!', value: true });
    expect(eval_('parse ["a"] [integer! | string!]')).toEqual({ type: 'logic!', value: true });
  });

  test('pipe fails if no match', () => {
    expect(eval_('parse [true] [integer! | string!]')).toEqual({ type: 'logic!', value: false });
  });
});

describe('parse block — extraction', () => {
  test('set-word captures value', () => {
    const ev = new Evaluator();
    ev.evalString('parse [42] [x: integer!]');
    expect(ev.evalString('x')).toEqual({ type: 'integer!', value: 42 });
  });

  test('multiple captures', () => {
    const ev = new Evaluator();
    ev.evalString("parse [name \"Alice\" age 25] ['name who: string! 'age years: integer!]");
    expect(ev.evalString('who')).toEqual({ type: 'string!', value: 'Alice' });
    expect(ev.evalString('years')).toEqual({ type: 'integer!', value: 25 });
  });
});

describe('parse block — lookahead', () => {
  test('not succeeds when sub-rule fails', () => {
    expect(eval_('parse [1] [not string! integer!]')).toEqual({ type: 'logic!', value: true });
  });

  test('ahead matches without consuming', () => {
    expect(eval_('parse [1] [ahead integer! integer!]')).toEqual({ type: 'logic!', value: true });
  });
});

describe('parse block — scanning', () => {
  test('thru scans past type match', () => {
    expect(eval_('parse [1 "a" 2] [thru string! integer!]')).toEqual({ type: 'logic!', value: true });
  });

  test('to scans to but not past match', () => {
    expect(eval_("parse [1 2 \"a\" 3] [to string! string! integer!]")).toEqual({ type: 'logic!', value: true });
  });
});

describe('parse block — collect/keep', () => {
  test('collect integers from mixed block', () => {
    const ev = new Evaluator();
    ev.evalString('parse [1 "a" 2 "b" 3] [nums: collect [some [keep integer! | skip]]]');
    const nums = ev.evalString('nums');
    expect(nums.type).toBe('block!');
    if (nums.type === 'block!') {
      expect(nums.values).toEqual([
        { type: 'integer!', value: 1 },
        { type: 'integer!', value: 2 },
        { type: 'integer!', value: 3 },
      ]);
    }
  });
});

describe('parse block — into', () => {
  test('descend into nested block', () => {
    expect(eval_('parse [[1 2]] [into [integer! integer!]]')).toEqual({ type: 'logic!', value: true });
  });
});

describe('parse block — composable rules', () => {
  test('word resolves to block sub-rule', () => {
    const ev = new Evaluator();
    ev.evalString('int-pair: [integer! integer!]');
    expect(ev.evalString('parse [1 2] int-pair')).toEqual({ type: 'logic!', value: true });
  });
});

describe('is?', () => {
  test('sugar for parse', () => {
    const ev = new Evaluator();
    ev.evalString("user-shape: ['name string! 'age integer!]");
    expect(ev.evalString('is? [name "Alice" age 25] user-shape')).toEqual({ type: 'logic!', value: true });
    expect(ev.evalString('is? [name "Alice"] user-shape')).toEqual({ type: 'logic!', value: false });
  });
});

describe('parse string — stub', () => {
  test('throws not yet implemented', () => {
    expect(() => eval_('parse "hello" [some alpha]')).toThrow('not yet implemented');
  });
});
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bun test src/tests/parse.test.ts`

- [ ] **Step 3: Create `src/evaluator/parse.ts`**

```typescript
import { KtgContext } from './context';
import {
  KtgValue, KtgBlock,
  NONE, isTruthy, KtgError,
} from './values';
import type { Evaluator } from './evaluator';

class ParseBreak {}

const TYPE_NAMES = new Set([
  'integer!', 'float!', 'string!', 'logic!', 'none!', 'char!',
  'pair!', 'tuple!', 'date!', 'time!', 'binary!', 'file!',
  'url!', 'email!', 'word!', 'set-word!', 'get-word!', 'lit-word!',
  'path!', 'block!', 'paren!', 'map!', 'object!', 'function!',
  'native!', 'op!', 'type!', 'operator!',
]);

export function parseBlock(
  input: KtgBlock,
  rules: KtgBlock,
  ctx: KtgContext,
  evaluator: Evaluator,
): boolean {
  const result = matchSequence(input.values, 0, rules.values, ctx, evaluator, []);
  return result !== null && result === input.values.length;
}

// Returns input position after matching, or null on failure.
// `ruleValues` is the full sequence of rules to match in order.
function matchSequence(
  input: KtgValue[],
  iPos: number,
  ruleValues: KtgValue[],
  ctx: KtgContext,
  evaluator: Evaluator,
  collectStack: KtgValue[][],
): number | null {
  // First, split on | at the top level
  const alternatives = splitOnPipe(ruleValues);
  if (alternatives.length > 1) {
    for (const alt of alternatives) {
      const result = matchSequenceInner(input, iPos, alt, ctx, evaluator, collectStack);
      if (result !== null) return result;
    }
    return null;
  }
  return matchSequenceInner(input, iPos, ruleValues, ctx, evaluator, collectStack);
}

function matchSequenceInner(
  input: KtgValue[],
  iPos: number,
  rules: KtgValue[],
  ctx: KtgContext,
  evaluator: Evaluator,
  collectStack: KtgValue[][],
): number | null {
  let rPos = 0;
  while (rPos < rules.length) {
    const rule = rules[rPos];

    // Set-word: capture
    if (rule.type === 'set-word!') {
      const captureName = rule.name;
      rPos++;
      if (rPos >= rules.length) return null;

      // Check if next is collect
      if (rules[rPos].type === 'word!' && (rules[rPos] as any).name === 'collect') {
        const startPos = iPos;
        const result = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack, false);
        if (result === null) return null;
        [iPos, rPos] = result;
        // The collect handler pushed the collected block into __collect_result
        // We read it back from the stack communication
        const lastCollect = collectStack.length > 0 ? null : null; // unused
        // Actually, collect stores result via ctx temporarily
        const collected = ctx.get('__parse_collect_result');
        if (collected) {
          ctx.set(captureName, collected);
        }
        continue;
      }

      const startPos = iPos;
      const result = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack, false);
      if (result === null) return null;
      [iPos, rPos] = result;
      // Capture matched value(s)
      if (iPos > startPos) {
        if (iPos - startPos === 1) {
          ctx.set(captureName, input[startPos]);
        } else {
          ctx.set(captureName, { type: 'block!', values: input.slice(startPos, iPos) });
        }
      }
      continue;
    }

    // Integer: could be repeat count
    if (rule.type === 'integer!' && rPos + 1 < rules.length) {
      const count = rule.value;
      // Check for range: N M rule
      if (rPos + 2 < rules.length && rules[rPos + 1].type === 'integer!') {
        const maxCount = (rules[rPos + 1] as any).value;
        rPos += 2;
        const result = matchRepeat(input, iPos, rules, rPos, ctx, evaluator, collectStack, count, maxCount);
        if (result === null) return null;
        [iPos, rPos] = result;
        continue;
      }
      // Exact repeat: N rule
      const nextRule = rules[rPos + 1];
      if (nextRule.type === 'word!' || nextRule.type === 'block!' || nextRule.type === 'lit-word!') {
        rPos++;
        const result = matchRepeat(input, iPos, rules, rPos, ctx, evaluator, collectStack, count, count);
        if (result === null) return null;
        [iPos, rPos] = result;
        continue;
      }
    }

    // Regular rule
    const result = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack, false);
    if (result === null) return null;
    [iPos, rPos] = result;
  }
  return iPos;
}

// Match a single rule. `asLiteral` forces integer to match literally (for to/thru targets).
// Returns [newIPos, newRPos] or null.
function matchOneRule(
  input: KtgValue[],
  iPos: number,
  rules: KtgValue[],
  rPos: number,
  ctx: KtgContext,
  evaluator: Evaluator,
  collectStack: KtgValue[][],
  asLiteral: boolean,
): [number, number] | null {
  const rule = rules[rPos];

  // Sub-rule block
  if (rule.type === 'block!') {
    const subResult = matchSequence(input, iPos, rule.values, ctx, evaluator, collectStack);
    if (subResult === null) return null;
    return [subResult, rPos + 1];
  }

  // Paren: side effect
  if (rule.type === 'paren!') {
    const inner: KtgBlock = { type: 'block!', values: rule.values };
    evaluator.evalBlock(inner, ctx);
    return [iPos, rPos + 1];
  }

  // Lit-word: match literal word in input
  if (rule.type === 'lit-word!') {
    if (iPos >= input.length) return null;
    const val = input[iPos];
    if (val.type === 'word!' && val.name === rule.name) return [iPos + 1, rPos + 1];
    if (val.type === 'lit-word!' && val.name === rule.name) return [iPos + 1, rPos + 1];
    return null;
  }

  // String literal: exact match in input
  if (rule.type === 'string!') {
    if (iPos >= input.length) return null;
    const val = input[iPos];
    if (val.type === 'string!' && val.value === rule.value) return [iPos + 1, rPos + 1];
    return null;
  }

  // Integer literal: match in input (when used as literal, e.g., inside to/thru)
  if (rule.type === 'integer!') {
    if (iPos >= input.length) return null;
    const val = input[iPos];
    if (val.type === 'integer!' && val.value === rule.value) return [iPos + 1, rPos + 1];
    return null;
  }

  // Word: keyword or composable rule
  if (rule.type === 'word!') {
    const name = rule.name;

    switch (name) {
      case 'end':
        return iPos >= input.length ? [iPos, rPos + 1] : null;

      case 'skip':
        return iPos < input.length ? [iPos + 1, rPos + 1] : null;

      case 'fail':
        return null;

      case 'some': {
        rPos++;
        let pos = iPos;
        let matched = 0;
        while (true) {
          const r = matchOneRule(input, pos, rules, rPos, ctx, evaluator, collectStack, false);
          if (r === null || r[0] === pos) break;
          pos = r[0];
          matched++;
        }
        return matched > 0 ? [pos, rPos + 1] : null;
      }

      case 'any': {
        rPos++;
        let pos = iPos;
        while (true) {
          const r = matchOneRule(input, pos, rules, rPos, ctx, evaluator, collectStack, false);
          if (r === null || r[0] === pos) break;
          pos = r[0];
        }
        return [pos, rPos + 1];
      }

      case 'opt': {
        rPos++;
        const r = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack, false);
        return r !== null ? [r[0], rPos + 1] : [iPos, rPos + 1];
      }

      case 'not': {
        rPos++;
        const r = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack, false);
        return r === null ? [iPos, rPos + 1] : null;
      }

      case 'ahead': {
        rPos++;
        const r = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack, false);
        return r !== null ? [iPos, rPos + 1] : null;
      }

      case 'to': {
        rPos++;
        for (let scan = iPos; scan < input.length; scan++) {
          const r = matchOneRule(input, scan, rules, rPos, ctx, evaluator, collectStack, true);
          if (r !== null) return [scan, rPos + 1];
        }
        return null;
      }

      case 'thru': {
        rPos++;
        for (let scan = iPos; scan < input.length; scan++) {
          const r = matchOneRule(input, scan, rules, rPos, ctx, evaluator, collectStack, true);
          if (r !== null) return [r[0], rPos + 1];
        }
        return null;
      }

      case 'into': {
        rPos++;
        if (iPos >= input.length) return null;
        const val = input[iPos];
        if (val.type !== 'block!') return null;
        const subRule = rules[rPos];
        if (!subRule || subRule.type !== 'block!') return null;
        const subResult = matchSequence(val.values, 0, subRule.values, ctx, evaluator, collectStack);
        if (subResult === null || subResult !== val.values.length) return null;
        return [iPos + 1, rPos + 1];
      }

      case 'quote': {
        rPos++;
        if (rPos >= rules.length || iPos >= input.length) return null;
        const expected = rules[rPos];
        const actual = input[iPos];
        if (JSON.stringify(expected) === JSON.stringify(actual)) return [iPos + 1, rPos + 1];
        return null;
      }

      case 'break':
        throw new ParseBreak();

      case 'collect': {
        rPos++;
        if (rPos >= rules.length || rules[rPos].type !== 'block!') return null;
        const collectRule = rules[rPos] as KtgBlock;
        const collected: KtgValue[] = [];
        collectStack.push(collected);
        const r = matchSequence(input, iPos, collectRule.values, ctx, evaluator, collectStack);
        collectStack.pop();
        if (r === null) return null;
        // Store for set-word capture
        ctx.set('__parse_collect_result', { type: 'block!', values: collected });
        return [r, rPos + 1];
      }

      case 'keep': {
        rPos++;
        const startPos = iPos;
        const r = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack, false);
        if (r === null) return null;
        if (collectStack.length > 0) {
          const bucket = collectStack[collectStack.length - 1];
          for (let k = startPos; k < r[0]; k++) {
            bucket.push(input[k]);
          }
        }
        return [r[0], rPos + 1];
      }

      default: {
        // Type match: word ending in !
        if (name.endsWith('!') && TYPE_NAMES.has(name)) {
          if (iPos >= input.length) return null;
          return input[iPos].type === name ? [iPos + 1, rPos + 1] : null;
        }

        // Composable rule: look up word in context
        const bound = ctx.get(name);
        if (bound && bound.type === 'block!') {
          const subResult = matchSequence(input, iPos, bound.values, ctx, evaluator, collectStack);
          if (subResult === null) return null;
          return [subResult, rPos + 1];
        }

        return null;
      }
    }
  }

  return null;
}

function matchRepeat(
  input: KtgValue[],
  iPos: number,
  rules: KtgValue[],
  rPos: number,
  ctx: KtgContext,
  evaluator: Evaluator,
  collectStack: KtgValue[][],
  minCount: number,
  maxCount: number,
): [number, number] | null {
  let pos = iPos;
  let matched = 0;
  while (matched < maxCount) {
    const r = matchOneRule(input, pos, rules, rPos, ctx, evaluator, collectStack, false);
    if (r === null || r[0] === pos) break;
    pos = r[0];
    matched++;
  }
  if (matched < minCount) return null;
  return [pos, rPos + 1];
}

function splitOnPipe(rules: KtgValue[]): KtgValue[][] {
  const alternatives: KtgValue[][] = [];
  let current: KtgValue[] = [];
  for (const rule of rules) {
    if (rule.type === 'operator!' && (rule as any).symbol === '|') {
      alternatives.push(current);
      current = [];
    } else {
      current.push(rule);
    }
  }
  alternatives.push(current);
  return alternatives.length === 1 && alternatives[0].length === rules.length
    ? [rules] // no pipe found, return original
    : alternatives;
}
```

- [ ] **Step 4: Register `parse` and `is?` natives**

In `src/evaluator/natives.ts`, add after the error handling section:

```typescript
  // === Group J: Parse ===

  const { parseBlock } = require('./parse');

  native('parse', 2, (args, ev, callerCtx) => {
    const [input, rules] = args;
    if (input.type === 'string!') {
      throw new KtgError('parse', 'String parsing not yet implemented');
    }
    if (input.type !== 'block!') throw new KtgError('type', 'parse expects a block or string');
    if (rules.type !== 'block!') throw new KtgError('type', 'parse expects a rule block');
    return { type: 'logic!', value: parseBlock(input, rules, callerCtx, ev) };
  });

  native('is?', 2, (args, ev, callerCtx) => {
    const [input, rules] = args;
    if (input.type !== 'block!') throw new KtgError('type', 'is? expects a block');
    if (rules.type !== 'block!') throw new KtgError('type', 'is? expects a rule block');
    return { type: 'logic!', value: parseBlock(input, rules, callerCtx, ev) };
  });
```

- [ ] **Step 5: Run tests**

Run: `bun test src/tests/parse.test.ts`

- [ ] **Step 6: Run full suite and commit**

Run: `bun test`

```
feat: add block parsing dialect with is? sugar
```

---

## Final Verification

- [ ] **Run full test suite**

Run: `bun test`
Expected: All tests pass (208 original + ~55 new)

- [ ] **Smoke test spec examples**

```typescript
// In a test or scratch file:
const ev = new Evaluator();

// Shape validation
ev.evalString("user-shape: ['name string! 'age integer!]");
ev.evalString('is? [name "Alice" age 25] user-shape'); // true

// Factorial with error handling
ev.evalString('fact: function [n] [either n = 0 [1] [n * fact (n - 1)]]');
ev.evalString('result: try [fact 10]');
ev.evalString("select result 'value"); // 3628800

// Loop/partition
ev.evalString('set [evens odds] loop/partition [for [x] from 1 to 10 [even? x]]');

// Object
ev.evalString('p: object [x: 10 y: 20]');
ev.evalString('p/x'); // 10
```
