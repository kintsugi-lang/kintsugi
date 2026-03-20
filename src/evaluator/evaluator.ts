import { KtgContext } from './context';
import {
  KtgValue, KtgBlock, KtgOp, KtgFunction, KtgNative,
  NONE, KtgError, BreakSignal, ReturnSignal,
  astToValue, isCallable, isTruthy, numVal, isNumeric,
  valueToString,
} from './values';
import { parseString } from '@/helpers';
import { registerNatives } from './natives';

export class Evaluator {
  public global: KtgContext;
  public output: string[] = [];

  constructor() {
    this.global = new KtgContext();
    registerNatives(this.global, this);
  }

  evalString(input: string): KtgValue {
    const ast = parseString(input);
    const block = astToValue(ast) as KtgBlock;
    const processed = this.preprocess(block);
    return this.evalBlock(processed, this.global);
  }

  preprocess(block: KtgBlock): KtgBlock {
    const values = block.values;
    const result: KtgValue[] = [];
    let i = 0;

    while (i < values.length) {
      const v = values[i];

      // #preprocess [block] — evaluate, collect emits, splice in
      if (v.type === 'word!' && v.name === '#preprocess' && i + 1 < values.length && values[i + 1].type === 'block!') {
        const ppBlock = values[i + 1] as KtgBlock;
        const emitted: KtgBlock[] = [];

        const ppCtx = new KtgContext(this.global);
        ppCtx.set('platform', { type: 'lit-word!', name: 'script' });
        ppCtx.set('emit', {
          type: 'native!', name: 'emit', arity: 1,
          fn: (args: KtgValue[]) => {
            if (args[0].type === 'block!') emitted.push(args[0] as KtgBlock);
            return NONE;
          },
        } as any);

        this.evalBlock(ppBlock, ppCtx);

        // Splice emitted blocks' values into the result
        for (const emittedBlock of emitted) {
          result.push(...emittedBlock.values);
        }

        i += 2;
        continue;
      }

      // #inline [block] — evaluate, replace with result
      if (v.type === 'word!' && v.name === '#inline' && i + 1 < values.length && values[i + 1].type === 'block!') {
        const inlineBlock = values[i + 1] as KtgBlock;
        const inlineResult = this.evalBlock(inlineBlock, this.global);
        result.push(inlineResult);
        i += 2;
        continue;
      }

      result.push(v);
      i++;
    }

    return { type: 'block!', values: result };
  }

  evalBlock(block: KtgBlock, ctx: KtgContext): KtgValue {
    const values = block.values;

    // Scan for lifecycle hooks
    const { body, enter, exit } = extractLifecycleHooks(values);

    // Run @enter
    if (enter) this.evalBlock(enter, ctx);

    try {
      let result: KtgValue = NONE;
      let pos = 0;

      while (pos < body.length) {
        [result, pos] = this.evalNext(body, pos, ctx);

        while (pos < body.length && this.nextIsInfix(body, pos, ctx)) {
          [result, pos] = this.applyInfix(result, body, pos, ctx);
        }
      }

      return result;
    } finally {
      // @exit always runs, even on error
      if (exit) {
        try { this.evalBlock(exit, ctx); } catch {}
      }
    }
  }

  evalNext(values: KtgValue[], pos: number, ctx: KtgContext): [KtgValue, number] {
    const val = values[pos];

    switch (val.type) {
      // Scalars — return self
      case 'integer!':
      case 'float!':
      case 'string!':
      case 'logic!':
      case 'none!':
      case 'pair!':
      case 'tuple!':
      case 'date!':
      case 'time!':
      case 'file!':
      case 'url!':
      case 'email!':
      case 'type!':
      case 'map!':
      case 'context!':
      case 'function!':
      case 'native!':
      case 'op!':
        return [val, pos + 1];

      case 'block!':
        return [val, pos + 1];

      case 'paren!': {
        const inner: KtgBlock = { type: 'block!', values: val.values };
        const result = this.evalBlock(inner, ctx);
        return [result, pos + 1];
      }

      case 'word!': {
        const lookupCtx = val.bound ?? ctx;
        const bound = lookupCtx.get(val.name);
        if (bound === undefined) {
          throw new KtgError('undefined', `${val.name} has no value`);
        }

        if (isCallable(bound)) {
          return this.callCallable(bound, values, pos + 1, ctx);
        }

        if (bound.type === 'op!') {
          return [bound, pos + 1];
        }

        return [bound, pos + 1];
      }

      case 'set-word!': {
        let [result, nextPos] = this.evalNext(values, pos + 1, ctx);
        while (nextPos < values.length && this.nextIsInfix(values, nextPos, ctx)) {
          [result, nextPos] = this.applyInfix(result, values, nextPos, ctx);
        }
        const setCtx = val.bound ?? ctx;
        setCtx.set(val.name, result);
        return [result, nextPos];
      }

      case 'get-word!': {
        const lookupCtx = val.bound ?? ctx;
        const bound = lookupCtx.get(val.name);
        if (bound === undefined) {
          throw new KtgError('undefined', `:${val.name} has no value`);
        }
        return [bound, pos + 1];
      }

      case 'lit-word!':
        return [val, pos + 1];

      case 'meta-word!': {
        const parts = val.name.split('/');
        const baseName = `@${parts[0]}`;
        const bound = ctx.get(baseName);
        if (bound && isCallable(bound)) {
          const refinements = parts.slice(1);
          return this.callCallable(bound, values, pos + 1, ctx, refinements);
        }
        return [val, pos + 1];
      }

      case 'operator!':
        // Operators should be consumed by infix handling, not appear here
        throw new KtgError('syntax', `Unexpected operator: ${val.symbol}`);

      case 'path!':
        return this.evalPath(val.segments, values, pos, ctx);

      case 'set-path!': {
        const segments = val.segments;
        // Resolve all but last segment
        let target = ctx.get(segments[0]);
        if (target === undefined) {
          throw new KtgError('undefined', `${segments[0]} has no value`);
        }
        for (let i = 1; i < segments.length - 1; i++) {
          target = this.accessField(target, segments[i]);
        }
        // Eval the value to assign
        let [assignVal, nextPos] = this.evalNext(values, pos + 1, ctx);
        while (nextPos < values.length && this.nextIsInfix(values, nextPos, ctx)) {
          [assignVal, nextPos] = this.applyInfix(assignVal, values, nextPos, ctx);
        }
        this.setField(target, segments[segments.length - 1], assignVal);
        return [assignVal, nextPos];
      }

      case 'get-path!': {
        let result = ctx.get(val.segments[0]);
        if (result === undefined) {
          throw new KtgError('undefined', `${val.segments[0]} has no value`);
        }
        for (let i = 1; i < val.segments.length; i++) {
          result = this.accessField(result, val.segments[i]);
        }
        return [result, pos + 1];
      }

      case 'lit-path!':
        return [val, pos + 1];

      default:
        return [NONE, pos + 1];
    }
  }

  // --- Infix ---

  nextIsInfix(values: KtgValue[], pos: number, ctx: KtgContext): boolean {
    if (pos >= values.length) return false;
    const val = values[pos];
    if (val.type === 'operator!') return true;
    if (val.type === 'word!') {
      const bound = ctx.get(val.name);
      return bound !== undefined && bound.type === 'op!';
    }
    return false;
  }

  applyInfix(left: KtgValue, values: KtgValue[], pos: number, ctx: KtgContext): [KtgValue, number] {
    const opVal = values[pos];
    let opFn: (l: KtgValue, r: KtgValue) => KtgValue;

    if (opVal.type === 'operator!') {
      const op = this.getBuiltinOp(opVal.symbol);
      opFn = op;
    } else if (opVal.type === 'word!') {
      const bound = ctx.get(opVal.name)!;
      if (bound.type === 'op!') {
        opFn = bound.fn;
      } else {
        throw new KtgError('type', `${opVal.name} is not an op!`);
      }
    } else {
      throw new KtgError('internal', 'Expected operator');
    }

    const [right, nextPos] = this.evalNext(values, pos + 1, ctx);
    return [opFn(left, right), nextPos];
  }

  private getBuiltinOp(symbol: string): (l: KtgValue, r: KtgValue) => KtgValue {
    switch (symbol) {
      case '+': return (l, r) => {
        if (l.type === 'string!' && r.type === 'string!') return { type: 'string!', value: l.value + r.value };
        if (l.type === 'string!') return { type: 'string!', value: l.value + valueToString(r) };
        return { type: isInt(l, r) ? 'integer!' : 'float!', value: numVal(l) + numVal(r) };
      };
      case '-': return (l, r) => ({ type: isInt(l, r) ? 'integer!' : 'float!', value: numVal(l) - numVal(r) });
      case '*': return (l, r) => ({ type: isInt(l, r) ? 'integer!' : 'float!', value: numVal(l) * numVal(r) });
      case '/': return (l, r) => {
        const rv = numVal(r);
        if (rv === 0) throw new KtgError('math', 'Division by zero');
        return { type: 'float!', value: numVal(l) / rv };
      };
      case '%': return (l, r) => ({ type: isInt(l, r) ? 'integer!' : 'float!', value: numVal(l) % numVal(r) });
      case '=':  return (l, r) => ({ type: 'logic!', value: valuesEqual(l, r) });
      case '<>': return (l, r) => ({ type: 'logic!', value: !valuesEqual(l, r) });
      case '<':  return (l, r) => ({ type: 'logic!', value: compareValues(l, r) < 0 });
      case '>':  return (l, r) => ({ type: 'logic!', value: compareValues(l, r) > 0 });
      case '<=': return (l, r) => ({ type: 'logic!', value: compareValues(l, r) <= 0 });
      case '>=': return (l, r) => ({ type: 'logic!', value: compareValues(l, r) >= 0 });
      default:
        throw new KtgError('syntax', `Unknown operator: ${symbol}`);
    }
  }

  // --- Path evaluation ---

  private evalPath(segments: string[], values: KtgValue[], pos: number, ctx: KtgContext): [KtgValue, number] {
    const headName = segments[0];
    let result = ctx.get(headName);
    if (result === undefined) {
      throw new KtgError('undefined', `${headName} has no value`);
    }

    // Collect refinement names if the head is callable
    if (isCallable(result)) {
      const refinements = segments.slice(1);
      return this.callCallable(result, values, pos + 1, ctx, refinements);
    }

    // Otherwise, navigate into the value
    for (let i = 1; i < segments.length; i++) {
      result = this.accessField(result, segments[i]);
    }

    // If the resolved value is callable, call it
    if (isCallable(result)) {
      return this.callCallable(result, values, pos + 1, ctx);
    }

    return [result, pos + 1];
  }

  accessField(target: KtgValue, field: string): KtgValue {
    if (target.type === 'block!') {
      const idx = parseInt(field, 10);
      if (!isNaN(idx)) {
        if (idx < 1 || idx > target.values.length) return NONE;
        return target.values[idx - 1]; // 1-based indexing
      }
    }
    if (target.type === 'map!') {
      return target.entries.get(field) ?? NONE;
    }
    if (target.type === 'context!') {
      return target.context.get(field) ?? NONE;
    }
    throw new KtgError('type', `Cannot access field '${field}' on ${target.type}`);
  }

  private setField(target: KtgValue, field: string, value: KtgValue): void {
    if (target.type === 'block!') {
      const idx = parseInt(field, 10);
      if (!isNaN(idx) && idx >= 1 && idx <= target.values.length) {
        target.values[idx - 1] = value;
        return;
      }
    }
    if (target.type === 'map!') {
      target.entries.set(field, value);
      return;
    }
    if (target.type === 'context!') {
      target.context.set(field, value);
      return;
    }
    throw new KtgError('type', `Cannot set field '${field}' on ${target.type}`);
  }

  // --- Calling ---

  callCallable(fn: KtgFunction | KtgNative, values: KtgValue[], pos: number, ctx: KtgContext, refinements?: string[]): [KtgValue, number] {
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

    return this.callFunction(fn, values, pos, ctx, refinements);
  }

  callFunction(fn: KtgFunction, values: KtgValue[], pos: number, ctx: KtgContext, refinements?: string[]): [KtgValue, number] {
    const childCtx = fn.closure.child();

    // Bind params with type checking
    for (const param of fn.spec.params) {
      if (pos >= values.length) {
        throw new KtgError('args', `Function expects argument '${param.name}'`);
      }
      let [arg, nextPos] = this.evalNext(values, pos, ctx);
      while (nextPos < values.length && this.nextIsInfix(values, nextPos, ctx)) {
        [arg, nextPos] = this.applyInfix(arg, values, nextPos, ctx);
      }
      if (param.typeConstraint) {
        checkType(arg, param.typeConstraint, param.name, ctx, this, param.elementType);
      }
      childCtx.set(param.name, arg);
      pos = nextPos;
    }

    // Bind refinements
    const activeRefinements = new Set(refinements ?? []);
    for (const ref of fn.spec.refinements) {
      const active = activeRefinements.has(ref.name);
      childCtx.set(ref.name, { type: 'logic!', value: active });
      for (const rp of ref.params) {
        if (active && pos < values.length) {
          let [arg, nextPos] = this.evalNext(values, pos, ctx);
          while (nextPos < values.length && this.nextIsInfix(values, nextPos, ctx)) {
            [arg, nextPos] = this.applyInfix(arg, values, nextPos, ctx);
          }
          if (rp.typeConstraint) {
            checkType(arg, rp.typeConstraint, rp.name, ctx, this);
          }
          childCtx.set(rp.name, arg);
          pos = nextPos;
        } else {
          childCtx.set(rp.name, NONE);
        }
      }
    }

    // Eval body with return type checking
    try {
      const result = this.evalBlock(fn.body, childCtx);
      if (fn.spec.returnType) {
        checkType(result, fn.spec.returnType, 'return', ctx, this);
      }
      return [result, pos];
    } catch (e) {
      if (e instanceof ReturnSignal) {
        if (fn.spec.returnType) {
          checkType(e.value, fn.spec.returnType, 'return', ctx, this);
        }
        return [e.value, pos];
      }
      throw e;
    }
  }
}

// --- Lifecycle hook extraction ---

function extractLifecycleHooks(values: KtgValue[]): {
  body: KtgValue[];
  enter: KtgBlock | null;
  exit: KtgBlock | null;
} {
  let enter: KtgBlock | null = null;
  let exit: KtgBlock | null = null;
  const body: KtgValue[] = [];

  let i = 0;
  while (i < values.length) {
    const v = values[i];
    if (v.type === 'meta-word!' && v.name === 'enter' && i + 1 < values.length && values[i + 1].type === 'block!') {
      enter = values[i + 1] as KtgBlock;
      i += 2;
    } else if (v.type === 'meta-word!' && v.name === 'exit' && i + 1 < values.length && values[i + 1].type === 'block!') {
      exit = values[i + 1] as KtgBlock;
      i += 2;
    } else {
      body.push(v);
      i++;
    }
  }

  return { body, enter, exit };
}

// --- Helpers ---

// --- Type checking ---

const TYPESETS: Record<string, string[]> = {
  'number!': ['integer!', 'float!'],
  'any-word!': ['word!', 'set-word!', 'get-word!', 'lit-word!', 'meta-word!'],
  'any-block!': ['block!', 'paren!', 'path!'],
  'scalar!': ['integer!', 'float!', 'date!', 'time!', 'pair!', 'tuple!'],
  'any-type!': [], // matches everything
};

function checkType(value: KtgValue, constraint: string, paramName: string, ctx?: KtgContext, evaluator?: Evaluator, elementType?: string): void {
  if (constraint === 'any-type!') return;

  // Check built-in type unions (number!, any-word!, etc.)
  const builtinUnion = TYPESETS[constraint];
  if (builtinUnion) {
    if (!builtinUnion.includes(value.type)) {
      throw new KtgError('type', `${paramName} expects ${constraint}, got ${value.type}`);
    }
    return;
  }

  // Check user-defined types (@type) from context
  if (ctx) {
    const resolved = ctx.get(constraint);
    if (resolved && resolved.type === 'type!' && resolved.rule && evaluator) {
      const { parseBlock } = require('./parse');
      const input = value.type === 'block!'
        ? value
        : { type: 'block!' as const, values: [value] };
      if (!parseBlock(input as any, resolved.rule, ctx, evaluator)) {
        throw new KtgError('type', `${paramName} expects ${constraint}, got ${value.type}`);
      }
      // Check where clause if present
      if (resolved.guard) {
        const guardCtx = new KtgContext(ctx);
        guardCtx.set('it', value);
        const guardResult = evaluator.evalBlock(resolved.guard, guardCtx);
        if (!isTruthy(guardResult)) {
          throw new KtgError('type', `${paramName} fails where clause for ${constraint}`);
        }
      }
      return;
    }
  }

  // For function?, match both function! and native!
  if (constraint === 'function!' && (value.type === 'function!' || value.type === 'native!')) return;

  if (value.type !== constraint) {
    throw new KtgError('type', `${paramName} expects ${constraint}, got ${value.type}`);
  }

  // Check element type for typed blocks
  if (elementType && value.type === 'block!' && value.values) {
    for (const elem of value.values) {
      if (elem.type !== elementType) {
        throw new KtgError('type', `${paramName} expects ${constraint} of ${elementType}, got ${elem.type} element`);
      }
    }
  }
}

function isInt(l: KtgValue, r: KtgValue): boolean {
  return l.type === 'integer!' && r.type === 'integer!';
}

function valuesEqual(a: KtgValue, b: KtgValue): boolean {
  if (a.type === 'none!' && b.type === 'none!') return true;
  if (isNumeric(a) && isNumeric(b)) return numVal(a) === numVal(b);
  if (a.type === 'string!' && b.type === 'string!') return a.value === b.value;
  if (a.type === 'logic!' && b.type === 'logic!') return a.value === b.value;
  if (a.type === 'word!' && b.type === 'word!') return a.name === b.name;
  if (a.type === 'lit-word!' && b.type === 'lit-word!') return a.name === b.name;
  if (a.type === 'meta-word!' && b.type === 'meta-word!') return a.name === b.name;
  return false;
}

function compareValues(a: KtgValue, b: KtgValue): number {
  if (isNumeric(a) && isNumeric(b)) return numVal(a) - numVal(b);
  if (a.type === 'string!' && b.type === 'string!') return a.value < b.value ? -1 : a.value > b.value ? 1 : 0;
  throw new KtgError('type', `Cannot compare ${a.type} and ${b.type}`);
}
