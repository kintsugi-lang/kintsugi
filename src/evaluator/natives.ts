import { KtgContext } from './context';
import {
  KtgValue, KtgBlock, KtgNative, KtgOp,
  NONE, TRUE, FALSE,
  isTruthy, typeOf, valueToString, numVal, isNumeric, isCallable,
  KtgError, BreakSignal, ReturnSignal,
} from './values';
import type { Evaluator } from './evaluator';

export function registerNatives(ctx: KtgContext, evaluator: Evaluator): void {
  const native = (
    name: string,
    arity: number,
    fn: (args: KtgValue[], ev: Evaluator, callerCtx: KtgContext, refinements: string[]) => KtgValue,
    refinementArgs?: Record<string, number>,
  ) => {
    ctx.set(name, { type: 'native!', name, arity, refinementArgs, fn } as KtgNative);
  };

  const op = (name: string, fn: (l: KtgValue, r: KtgValue) => KtgValue) => {
    ctx.set(name, { type: 'op!', name, fn } as KtgOp);
  };

  // === Group A: Output ===

  native('print', 1, (args, ev) => {
    ev.output.push(valueToString(args[0]));
    return NONE;
  });

  native('probe', 1, (args, ev) => {
    ev.output.push(valueToString(args[0]));
    return args[0];
  });

  // === Group B: Control Flow ===

  native('if', 2, (args, ev, callerCtx) => {
    const [cond, block] = args;
    if (block.type !== 'block!') throw new KtgError('type', 'if expects a block as second argument');
    if (isTruthy(cond)) return ev.evalBlock(block, callerCtx);
    return NONE;
  });

  native('either', 3, (args, ev, callerCtx) => {
    const [cond, trueBlock, falseBlock] = args;
    if (trueBlock.type !== 'block!') throw new KtgError('type', 'either expects blocks');
    if (falseBlock.type !== 'block!') throw new KtgError('type', 'either expects blocks');
    return isTruthy(cond) ? ev.evalBlock(trueBlock, callerCtx) : ev.evalBlock(falseBlock, callerCtx);
  });

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

  native('break', 0, () => {
    throw new BreakSignal();
  });

  native('return', 1, (args) => {
    throw new ReturnSignal(args[0]);
  });

  native('not', 1, (args) => {
    return isTruthy(args[0]) ? FALSE : TRUE;
  });

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

  // === Group C: Infix ops ===

  op('and', (l, r) => isTruthy(l) ? r : l);
  op('or', (l, r) => isTruthy(l) ? l : r);

  // === Group D: Block Operations ===

  native('length?', 1, (args) => {
    const v = args[0];
    if (v.type === 'block!') return { type: 'integer!', value: v.values.length };
    if (v.type === 'string!') return { type: 'integer!', value: v.value.length };
    if (v.type === 'map!') return { type: 'integer!', value: v.entries.size };
    throw new KtgError('type', `length? not supported for ${v.type}`);
  });

  native('empty?', 1, (args) => {
    const v = args[0];
    if (v.type === 'block!') return { type: 'logic!', value: v.values.length === 0 };
    if (v.type === 'string!') return { type: 'logic!', value: v.value.length === 0 };
    if (v.type === 'map!') return { type: 'logic!', value: v.entries.size === 0 };
    throw new KtgError('type', `empty? not supported for ${v.type}`);
  });

  native('first', 1, (args) => {
    const v = args[0];
    if (v.type === 'block!') return v.values[0] ?? NONE;
    if (v.type === 'string!') return v.value.length > 0 ? { type: 'char!', value: v.value[0] } : NONE;
    throw new KtgError('type', `first not supported for ${v.type}`);
  });

  native('second', 1, (args) => {
    const v = args[0];
    if (v.type === 'block!') return v.values[1] ?? NONE;
    throw new KtgError('type', `second not supported for ${v.type}`);
  });

  native('last', 1, (args) => {
    const v = args[0];
    if (v.type === 'block!') return v.values.length > 0 ? v.values[v.values.length - 1] : NONE;
    if (v.type === 'string!') return v.value.length > 0 ? { type: 'char!', value: v.value[v.value.length - 1] } : NONE;
    throw new KtgError('type', `last not supported for ${v.type}`);
  });

  native('pick', 2, (args) => {
    const [series, index] = args;
    if (index.type !== 'integer!') throw new KtgError('type', 'pick expects integer index');
    if (series.type === 'block!') return series.values[index.value - 1] ?? NONE;
    if (series.type === 'string!') {
      const ch = series.value[index.value - 1];
      return ch ? { type: 'char!', value: ch } : NONE;
    }
    throw new KtgError('type', `pick not supported for ${series.type}`);
  });

  native('copy', 1, (args) => {
    const v = args[0];
    if (v.type === 'block!') return { type: 'block!', values: [...v.values] };
    if (v.type === 'string!') return { type: 'string!', value: v.value };
    if (v.type === 'map!') return { type: 'map!', entries: new Map(v.entries) };
    return v;
  });

  native('append', 2, (args) => {
    const [series, value] = args;
    if (series.type === 'block!') {
      series.values.push(value);
      return series;
    }
    if (series.type === 'string!') {
      return { type: 'string!', value: series.value + valueToString(value) };
    }
    throw new KtgError('type', `append not supported for ${series.type}`);
  });

  native('insert', 3, (args) => {
    const [series, value, position] = args;
    if (position.type !== 'integer!') throw new KtgError('type', 'insert expects integer position');
    if (series.type === 'block!') {
      series.values.splice(position.value - 1, 0, value);
      return series;
    }
    throw new KtgError('type', `insert not supported for ${series.type}`);
  });

  native('remove', 2, (args) => {
    const [series, position] = args;
    if (series.type === 'block!') {
      if (position.type !== 'integer!') throw new KtgError('type', 'remove expects integer position');
      series.values.splice(position.value - 1, 1);
      return series;
    }
    if (series.type === 'map!') {
      const key = valueToString(position);
      series.entries.delete(key);
      return series;
    }
    throw new KtgError('type', `remove not supported for ${series.type}`);
  });

  native('select', 2, (args) => {
    const [series, key] = args;
    if (series.type === 'block!') {
      for (let i = 0; i < series.values.length - 1; i++) {
        if (valEq(series.values[i], key)) return series.values[i + 1];
      }
      return NONE;
    }
    if (series.type === 'map!') {
      const k = valueToString(key);
      return series.entries.get(k) ?? NONE;
    }
    throw new KtgError('type', `select not supported for ${series.type}`);
  });

  native('has?', 2, (args) => {
    const [series, value] = args;
    if (series.type === 'block!') {
      for (const v of series.values) {
        if (valEq(v, value)) return TRUE;
      }
      return FALSE;
    }
    if (series.type === 'string!') {
      if (value.type !== 'string!') throw new KtgError('type', 'has? in string expects string');
      return { type: 'logic!', value: series.value.includes(value.value) };
    }
    if (series.type === 'map!') {
      const k = valueToString(value);
      return { type: 'logic!', value: series.entries.has(k) };
    }
    throw new KtgError('type', `has? not supported for ${series.type}`);
  });

  native('index?', 2, (args) => {
    const [series, value] = args;
    if (series.type === 'block!') {
      for (let i = 0; i < series.values.length; i++) {
        if (valEq(series.values[i], value)) return { type: 'integer!', value: i + 1 };
      }
      return NONE;
    }
    if (series.type === 'string!') {
      if (value.type !== 'string!') throw new KtgError('type', 'index? in string expects string');
      const idx = series.value.indexOf(value.value);
      return idx === -1 ? NONE : { type: 'integer!', value: idx + 1 };
    }
    throw new KtgError('type', `index? not supported for ${series.type}`);
  });

  // === Group E: Type Operations ===

  native('type?', 1, (args) => {
    return { type: 'type!', name: typeOf(args[0]) };
  });

  native('to', 2, (args) => {
    const [targetType, value] = args;
    const typeName = targetType.type === 'type!' ? targetType.name : valueToString(targetType);
    switch (typeName) {
      case 'integer!':
        if (value.type === 'string!') return { type: 'integer!', value: parseInt(value.value, 10) };
        if (value.type === 'logic!') return { type: 'integer!', value: value.value ? 1 : 0 };
        if (value.type === 'char!') return { type: 'integer!', value: value.value.codePointAt(0) ?? 0 };
        if (isNumeric(value)) return { type: 'integer!', value: Math.trunc(numVal(value)) };
        break;
      case 'float!':
        if (value.type === 'string!') return { type: 'float!', value: parseFloat(value.value) };
        if (value.type === 'logic!') return { type: 'float!', value: value.value ? 1.0 : 0.0 };
        if (isNumeric(value)) return { type: 'float!', value: numVal(value) };
        break;
      case 'string!':
        if (value.type === 'block!') return { type: 'string!', value: value.values.map(valueToString).join(' ') };
        return { type: 'string!', value: valueToString(value) };
      case 'char!':
        if (value.type === 'integer!') return { type: 'char!', value: String.fromCodePoint(value.value) };
        if (value.type === 'string!' && value.value.length > 0) return { type: 'char!', value: value.value[0] };
        break;
      case 'logic!':
        return { type: 'logic!', value: isTruthy(value) };
      case 'word!': {
        const n = wordNameOf(value);
        if (n !== null) return { type: 'word!', name: n };
        break;
      }
      case 'set-word!': {
        const n = wordNameOf(value);
        if (n !== null) return { type: 'set-word!', name: n };
        break;
      }
      case 'lit-word!': {
        const n = wordNameOf(value);
        if (n !== null) return { type: 'lit-word!', name: n };
        break;
      }
      case 'get-word!': {
        const n = wordNameOf(value);
        if (n !== null) return { type: 'get-word!', name: n };
        break;
      }
      case 'block!':
        if (value.type === 'string!') return { type: 'block!', values: [value] };
        if (value.type === 'block!') return value;
        return { type: 'block!', values: [value] };
    }
    throw new KtgError('type', `Cannot convert ${value.type} to ${typeName}`);
  });

  native('make', 2, (args) => {
    const [targetType, spec] = args;
    const typeName = targetType.type === 'type!' ? targetType.name : valueToString(targetType);
    if (typeName === 'map!' && spec.type === 'block!') {
      const entries = new Map<string, KtgValue>();
      for (let i = 0; i < spec.values.length - 1; i += 2) {
        const key = spec.values[i];
        const val = spec.values[i + 1];
        const keyStr = key.type === 'set-word!' ? key.name : valueToString(key);
        entries.set(keyStr, val);
      }
      return { type: 'map!', entries };
    }
    throw new KtgError('type', `make not supported for ${typeName}`);
  });

  native('context', 1, (args, ev, callerCtx) => {
    const block = args[0];
    if (block.type !== 'block!') throw new KtgError('type', 'context expects a block');
    const childCtx = new KtgContext(callerCtx);
    ev.evalBlock(block, childCtx);
    return { type: 'context!', context: childCtx };
  });

  // === Group F: String Operations ===

  native('join', 2, (args) => {
    const left = valueToString(args[0]);
    const right = args[1].type === 'block!'
      ? args[1].values.map(valueToString).join('')
      : valueToString(args[1]);
    return { type: 'string!', value: left + right };
  });

  native('rejoin', 1, (args, ev, callerCtx) => {
    const v = args[0];
    if (v.type !== 'block!') throw new KtgError('type', 'rejoin expects a block');
    // Evaluate each expression in the block, then join as strings
    const parts: string[] = [];
    const values = v.values;
    let pos = 0;
    while (pos < values.length) {
      let [result, nextPos] = ev.evalNext(values, pos, callerCtx);
      while (nextPos < values.length && ev.nextIsInfix(values, nextPos, callerCtx)) {
        [result, nextPos] = ev.applyInfix(result, values, nextPos, callerCtx);
      }
      parts.push(valueToString(result));
      pos = nextPos;
    }
    return { type: 'string!', value: parts.join('') };
  });

  native('trim', 1, (args) => {
    if (args[0].type !== 'string!') throw new KtgError('type', 'trim expects a string');
    return { type: 'string!', value: args[0].value.trim() };
  });

  native('split', 2, (args) => {
    if (args[0].type !== 'string!') throw new KtgError('type', 'split expects a string');
    const delim = valueToString(args[1]);
    const parts = args[0].value.split(delim);
    return { type: 'block!', values: parts.map(p => ({ type: 'string!' as const, value: p })) };
  });

  native('uppercase', 1, (args) => {
    if (args[0].type !== 'string!') throw new KtgError('type', 'uppercase expects a string');
    return { type: 'string!', value: args[0].value.toUpperCase() };
  });

  native('lowercase', 1, (args) => {
    if (args[0].type !== 'string!') throw new KtgError('type', 'lowercase expects a string');
    return { type: 'string!', value: args[0].value.toLowerCase() };
  });

  native('replace', 3, (args) => {
    if (args[0].type !== 'string!') throw new KtgError('type', 'replace expects a string');
    const str = args[0].value;
    const from = valueToString(args[1]);
    const to = valueToString(args[2]);
    return { type: 'string!', value: str.replace(from, to) };
  });

  // === Group G: Math Utilities ===

  native('min', 2, (args) => {
    return numVal(args[0]) <= numVal(args[1]) ? args[0] : args[1];
  });

  native('max', 2, (args) => {
    return numVal(args[0]) >= numVal(args[1]) ? args[0] : args[1];
  });

  native('abs', 1, (args) => {
    const v = numVal(args[0]);
    return args[0].type === 'float!' ? { type: 'float!', value: Math.abs(v) } : { type: 'integer!', value: Math.abs(v) };
  });

  native('negate', 1, (args) => {
    const v = numVal(args[0]);
    return args[0].type === 'float!' ? { type: 'float!', value: -v } : { type: 'integer!', value: -v };
  });

  native('round', 1, (args, _ev, _ctx, refinements) => {
    const v = numVal(args[0]);
    if (refinements.includes('down')) {
      return { type: 'integer!', value: Math.trunc(v) };
    }
    if (refinements.includes('up')) {
      return { type: 'integer!', value: v >= 0 ? Math.ceil(v) : Math.floor(v) };
    }
    return { type: 'integer!', value: Math.round(v) };
  });

  native('odd?', 1, (args) => {
    return { type: 'logic!', value: numVal(args[0]) % 2 !== 0 };
  });

  native('even?', 1, (args) => {
    return { type: 'logic!', value: numVal(args[0]) % 2 === 0 };
  });

  // === Group H: Code-as-data ===

  native('do', 1, (args, ev, callerCtx) => {
    const v = args[0];
    if (v.type === 'block!') return ev.evalBlock(v, callerCtx);
    if (v.type === 'string!') return ev.evalString(v.value);
    return v;
  });

  native('reduce', 1, (args, ev, callerCtx) => {
    const v = args[0];
    if (v.type !== 'block!') throw new KtgError('type', 'reduce expects a block');
    const results: KtgValue[] = [];
    const values = v.values;
    let pos = 0;
    while (pos < values.length) {
      let [result, nextPos] = ev.evalNext(values, pos, callerCtx);
      while (nextPos < values.length && ev.nextIsInfix(values, nextPos, callerCtx)) {
        [result, nextPos] = ev.applyInfix(result, values, nextPos, callerCtx);
      }
      results.push(result);
      pos = nextPos;
    }
    return { type: 'block!', values: results };
  });

  native('compose', 1, (args, ev, callerCtx) => {
    const v = args[0];
    if (v.type !== 'block!') throw new KtgError('type', 'compose expects a block');
    return { type: 'block!', values: composeBlock(v, ev, callerCtx) };
  });

  native('set', 2, (args, _ev, callerCtx) => {
    const [words, values] = args;
    if (words.type === 'block!' && values.type === 'block!') {
      for (let i = 0; i < words.values.length; i++) {
        const w = words.values[i];
        const v = values.values[i] ?? NONE;
        if (w.type === 'word!' || w.type === 'set-word!') {
          callerCtx.set(w.name, v);
        }
      }
      return values;
    }
    throw new KtgError('type', 'set expects two blocks');
  });

  native('apply', 2, (args, ev, callerCtx) => {
    const [fn, argBlock] = args;
    if (!isCallable(fn)) throw new KtgError('type', 'apply expects a function');
    if (argBlock.type !== 'block!') throw new KtgError('type', 'apply expects a block of arguments');
    const [result] = ev.callCallable(fn, argBlock.values, 0, callerCtx);
    return result;
  });

  // Register function keyword
  const { createFunction } = require('./functions');
  native('function', 2, (args, _ev, callerCtx) => {
    return createFunction(args[0], args[1], callerCtx);
  });

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
  }, { handle: 1 });

  // #preprocess and #inline are handled in the preprocess pass (evaluator.ts),
  // not as natives. They run before evaluation.

  // === Group I-b: Binding & Introspection ===

  native('bind', 2, (args) => {
    const [block, target] = args;
    if (block.type !== 'block!') throw new KtgError('type', 'bind expects a block');
    if (target.type !== 'context!') throw new KtgError('type', 'bind expects a context');
    bindBlock(block, target.context);
    return block;
  });

  native('words-of', 1, (args) => {
    const v = args[0];
    if (v.type !== 'context!') throw new KtgError('type', 'words-of expects a context');
    const words: KtgValue[] = [];
    // KtgContext.keys() doesn't exist yet — we need to add it
    for (const name of v.context.keys()) {
      words.push({ type: 'word!', name });
    }
    return { type: 'block!', values: words };
  });

  // === Group I-d: Match Dialect ===

  native('match', 2, (args, ev, callerCtx) => {
    const [value, cases] = args;
    if (cases.type !== 'block!') throw new KtgError('type', 'match expects a cases block');

    // Normalize: wrap non-block values in a single-element block for positional matching
    const matchValues: KtgValue[] = value.type === 'block!' ? value.values : [value];

    const caseValues = cases.values;
    let i = 0;

    while (i < caseValues.length) {
      // Check for default:
      if (caseValues[i].type === 'set-word!' && (caseValues[i] as any).name === 'default') {
        i++;
        if (i < caseValues.length && caseValues[i].type === 'block!') {
          return ev.evalBlock(caseValues[i] as KtgBlock, callerCtx);
        }
        return NONE;
      }

      // Expect pattern block
      if (caseValues[i].type !== 'block!') { i++; continue; }
      const pattern = (caseValues[i] as KtgBlock).values;
      i++;

      // Check for 'when' guard before body
      let guard: KtgBlock | null = null;
      if (i < caseValues.length && caseValues[i].type === 'word!' && (caseValues[i] as any).name === 'when') {
        i++;
        if (i < caseValues.length && caseValues[i].type === 'block!') {
          guard = caseValues[i] as KtgBlock;
          i++;
        }
      }

      // Expect body block
      if (i >= caseValues.length || caseValues[i].type !== 'block!') continue;
      const body = caseValues[i] as KtgBlock;
      i++;

      // Try to match pattern against values
      const bindings = tryMatchPattern(pattern, matchValues, ev, callerCtx);
      if (bindings === null) continue;

      // Apply bindings to caller context
      for (const [name, val] of bindings) {
        callerCtx.set(name, val);
      }

      // Check guard if present
      if (guard) {
        if (!isTruthy(ev.evalBlock(guard, callerCtx))) continue;
      }

      // Match succeeded — evaluate body
      return ev.evalBlock(body, callerCtx);
    }

    return NONE;
  });

  // === Typesets ===

  // typeset [types] — creates a type union
  // typeset/where [types] [guard] — with a guard clause
  native('typeset', 1, (args, _ev, _callerCtx, refinements) => {
    const block = args[0];
    if (block.type !== 'block!') throw new KtgError('type', 'typeset expects a block of types');
    const types: string[] = [];
    for (const v of block.values) {
      if (v.type === 'word!' && v.name.endsWith('!')) types.push(v.name);
    }
    const guard = refinements.includes('where') && args[1]?.type === 'block!' ? args[1] as KtgBlock : undefined;
    return { type: 'typeset!', name: '', types, guard } as any;
  }, { where: 1 });

  // === Header ===
  // When running a file directly, the header is a no-op.
  // require consumes it before evaluation.
  native('Kintsugi', 1, () => NONE);

  // === Group I-e: Require ===

  const { requireModule } = require('./require');

  native('require', 1, (args, ev, callerCtx, refinements) => {
    const fileVal = args[0];
    if (fileVal.type !== 'file!') throw new KtgError('type', 'require expects a file! path');
    const headerOnly = refinements.includes('header');
    return requireModule(fileVal.value, ev, callerCtx, headerOnly);
  }, { header: 0 });

  // === Group I-f: Attempt Dialect ===

  native('attempt', 1, (args, ev, callerCtx) => {
    const block = args[0];
    if (block.type !== 'block!') throw new KtgError('type', 'attempt expects a block');
    const pipeline = parseAttemptDialect(block);

    // No source → return a reusable function
    if (!pipeline.source) {
      return createAttemptFunction(pipeline, ev, callerCtx);
    }

    return executeAttempt(pipeline, null, ev, callerCtx);
  });

  // === Group J: Parse ===

  const { parseBlock, parseString } = require('./parse');

  native('parse', 2, (args, ev, callerCtx) => {
    const [input, rules] = args;
    if (rules.type !== 'block!') throw new KtgError('type', 'parse expects a rule block');
    if (input.type === 'string!') {
      return { type: 'logic!', value: parseString(input.value, rules, callerCtx, ev) };
    }
    if (input.type !== 'block!') throw new KtgError('type', 'parse expects a block or string');
    return { type: 'logic!', value: parseBlock(input, rules, callerCtx, ev) };
  });

  native('is?', 2, (args, ev, callerCtx) => {
    const [input, rules] = args;
    if (input.type !== 'block!') throw new KtgError('type', 'is? expects a block');
    if (rules.type !== 'block!') throw new KtgError('type', 'is? expects a rule block');
    return { type: 'logic!', value: parseBlock(input, rules, callerCtx, ev) };
  });

  // === Type Names ===

  const typeNames = [
    'integer!', 'float!', 'string!', 'logic!', 'none!', 'char!',
    'pair!', 'tuple!', 'date!', 'time!', 'binary!', 'file!',
    'url!', 'email!', 'word!', 'set-word!', 'get-word!', 'lit-word!',
    'path!', 'block!', 'paren!', 'map!', 'context!', 'function!',
    'native!', 'op!', 'type!',
  ];

  for (const name of typeNames) {
    ctx.set(name, { type: 'type!', name } as KtgValue);
  }

  // Logic aliases — bound as words so dialects can use 'on'/'off' as keywords
  ctx.set('on', TRUE);
  ctx.set('off', FALSE);
  ctx.set('yes', TRUE);
  ctx.set('no', FALSE);

  // === Type Predicates ===

  native('function?', 1, (args) => ({
    type: 'logic!',
    value: args[0].type === 'function!' || args[0].type === 'native!',
  }));

  const typePredicates: [string, string][] = [
    ['none?', 'none!'], ['integer?', 'integer!'], ['float?', 'float!'],
    ['string?', 'string!'], ['logic?', 'logic!'], ['char?', 'char!'],
    ['block?', 'block!'], ['context?', 'context!'],
    ['pair?', 'pair!'], ['tuple?', 'tuple!'], ['date?', 'date!'],
    ['time?', 'time!'], ['binary?', 'binary!'], ['file?', 'file!'],
    ['url?', 'url!'], ['email?', 'email!'], ['word?', 'word!'],
    ['map?', 'map!'],
  ];

  for (const [name, typeName] of typePredicates) {
    native(name, 1, (args) => ({ type: 'logic!', value: args[0].type === typeName }));
  }
}

// --- Private helpers ---

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

function wordNameOf(v: KtgValue): string | null {
  if (v.type === 'string!') return v.value;
  if (v.type === 'word!' || v.type === 'set-word!' || v.type === 'get-word!' || v.type === 'lit-word!') return v.name;
  return null;
}

function wordName(v: KtgValue): string | null {
  if (v.type === 'word!' || v.type === 'set-word!' || v.type === 'get-word!' || v.type === 'lit-word!') return v.name;
  return null;
}

function valEq(a: KtgValue, b: KtgValue): boolean {
  if (a.type === 'none!' && b.type === 'none!') return true;
  if (isNumeric(a) && isNumeric(b)) return numVal(a) === numVal(b);
  if (a.type === 'string!' && b.type === 'string!') return a.value === b.value;
  if (a.type === 'logic!' && b.type === 'logic!') return a.value === b.value;
  const aName = wordName(a);
  const bName = wordName(b);
  if (aName !== null && bName !== null) return aName === bName;
  return false;
}

function tryMatchPattern(
  pattern: KtgValue[],
  values: KtgValue[],
  ev: Evaluator,
  ctx: KtgContext,
): Map<string, KtgValue> | null {
  // Special case: single wildcard [_] matches anything regardless of length
  if (pattern.length === 1 && pattern[0].type === 'word!' && (pattern[0] as any).name === '_') {
    return new Map();
  }

  // Single type match [integer!] — match single value by type
  if (pattern.length === 1 && pattern[0].type === 'word!' && (pattern[0] as any).name.endsWith('!')) {
    if (values.length === 1 && matchesType(values[0], (pattern[0] as any).name, ctx)) {
      return new Map();
    }
    return null;
  }

  // Single capture word [x] matches single value (values may be length 1 from wrapping)
  if (pattern.length === 1 && pattern[0].type === 'word!' && (pattern[0] as any).name !== '_') {
    if (values.length === 1) {
      return new Map([[(pattern[0] as any).name, values[0]]]);
    }
    return new Map([[(pattern[0] as any).name, { type: 'block!', values } as KtgValue]]);
  }

  // Positional matching: pattern and values must be same length
  if (pattern.length !== values.length) return null;

  const bindings = new Map<string, KtgValue>();

  for (let j = 0; j < pattern.length; j++) {
    const p = pattern[j];
    const v = values[j];

    if (p.type === 'word!' && (p as any).name === '_') {
      continue;
    }

    // Type match: word ending in !
    if (p.type === 'word!' && (p as any).name.endsWith('!')) {
      if (!matchesType(v, (p as any).name, ctx)) return null;
      continue;
    }

    if (p.type === 'word!') {
      bindings.set((p as any).name, v);
      continue;
    }

    if (p.type === 'lit-word!') {
      // Lit-word: match the word literally
      if (v.type === 'lit-word!' && v.name === (p as any).name) continue;
      if (v.type === 'word!' && v.name === (p as any).name) continue;
      return null;
    }

    if (p.type === 'paren!') {
      // Paren: evaluate expression, match against result
      const inner: KtgBlock = { type: 'block!', values: (p as any).values };
      const expected = ev.evalBlock(inner, ctx);
      if (!matchValuesEqual(expected, v)) return null;
      continue;
    }

    // Literal: match exactly
    if (!matchValuesEqual(p, v)) return null;
  }

  return bindings;
}

function matchesType(value: KtgValue, typeName: string, ctx: KtgContext): boolean {
  // Direct type match
  if (value.type === typeName) return true;
  // function! matches native! too
  if (typeName === 'function!' && value.type === 'native!') return true;
  // Built-in typesets
  const builtinSets: Record<string, string[]> = {
    'number!': ['integer!', 'float!'],
    'any-word!': ['word!', 'set-word!', 'get-word!', 'lit-word!'],
    'scalar!': ['integer!', 'float!', 'date!', 'time!', 'pair!', 'tuple!', 'char!'],
  };
  if (builtinSets[typeName]) return builtinSets[typeName].includes(value.type);
  // User-defined typesets from context
  const resolved = ctx.get(typeName);
  if (resolved && resolved.type === 'typeset!') return resolved.types.includes(value.type);
  return false;
}

function matchValuesEqual(a: KtgValue, b: KtgValue): boolean {
  if (a.type === 'none!' && b.type === 'none!') return true;
  if (a.type === 'integer!' && b.type === 'integer!') return a.value === b.value;
  if (a.type === 'float!' && b.type === 'float!') return a.value === b.value;
  if (a.type === 'string!' && b.type === 'string!') return a.value === b.value;
  if (a.type === 'logic!' && b.type === 'logic!') return a.value === b.value;
  if (a.type === 'char!' && b.type === 'char!') return a.value === b.value;
  if (a.type === 'lit-word!' && b.type === 'lit-word!') return a.name === b.name;
  if (a.type === 'word!' && b.type === 'word!') return a.name === b.name;
  // Cross-type word matching
  if (a.type === 'lit-word!' && b.type === 'word!') return a.name === b.name;
  if (a.type === 'word!' && b.type === 'lit-word!') return a.name === b.name;
  return false;
}

// --- Attempt dialect ---

interface AttemptPipeline {
  source: KtgBlock | null;
  steps: { type: 'then' | 'when'; block: KtgBlock }[];
  handlers: { kind: string; block: KtgBlock }[];
  retries: number;
  fallback: KtgBlock | null;
}

function parseAttemptDialect(block: KtgBlock): AttemptPipeline {
  const pipeline: AttemptPipeline = {
    source: null, steps: [], handlers: [], retries: 0, fallback: null,
  };
  const vals = block.values;
  let i = 0;

  while (i < vals.length) {
    const v = vals[i];
    if (v.type !== 'word!' && v.type !== 'lit-word!') { i++; continue; }

    const name = v.type === 'word!' ? v.name : '';

    if (name === 'on' && i + 2 < vals.length && vals[i + 1].type === 'lit-word!' && vals[i + 2].type === 'block!') {
      pipeline.handlers.push({ kind: (vals[i + 1] as any).name, block: vals[i + 2] as KtgBlock });
      i += 3;
    } else if (name === 'source' && i + 1 < vals.length && vals[i + 1].type === 'block!') {
      pipeline.source = vals[i + 1] as KtgBlock;
      i += 2;
    } else if (name === 'then' && i + 1 < vals.length && vals[i + 1].type === 'block!') {
      pipeline.steps.push({ type: 'then', block: vals[i + 1] as KtgBlock });
      i += 2;
    } else if (name === 'when' && i + 1 < vals.length && vals[i + 1].type === 'block!') {
      pipeline.steps.push({ type: 'when', block: vals[i + 1] as KtgBlock });
      i += 2;
    } else if (name === 'retries' && i + 1 < vals.length && vals[i + 1].type === 'integer!') {
      pipeline.retries = (vals[i + 1] as any).value;
      i += 2;
    } else if (name === 'fallback' && i + 1 < vals.length && vals[i + 1].type === 'block!') {
      pipeline.fallback = vals[i + 1] as KtgBlock;
      i += 2;
    } else {
      i++;
    }
  }

  return pipeline;
}

function executeAttempt(
  pipeline: AttemptPipeline,
  initialIt: KtgValue | null,
  ev: Evaluator,
  callerCtx: KtgContext,
): KtgValue {
  const attemptCtx = new KtgContext(callerCtx);
  let retriesLeft = pipeline.retries;

  const runPipeline = (): KtgValue => {
    let it: KtgValue = initialIt ?? NONE;

    // Run source if present
    if (pipeline.source) {
      attemptCtx.set('it', it);
      it = ev.evalBlock(pipeline.source, attemptCtx);
    }

    // Run steps
    for (const step of pipeline.steps) {
      attemptCtx.set('it', it);
      if (step.type === 'when') {
        const guardResult = ev.evalBlock(step.block, attemptCtx);
        if (!isTruthy(guardResult)) return NONE;
      } else {
        it = ev.evalBlock(step.block, attemptCtx);
      }
    }

    return it;
  };

  while (true) {
    try {
      return runPipeline();
    } catch (e) {
      if (e instanceof KtgError) {
        // Check named handlers
        for (const handler of pipeline.handlers) {
          if (handler.kind === e.errorName) {
            attemptCtx.set('it', e.data ?? NONE);
            return ev.evalBlock(handler.block, attemptCtx);
          }
        }

        // Retry if allowed
        if (retriesLeft > 0) {
          retriesLeft--;
          continue;
        }

        // Fallback
        if (pipeline.fallback) {
          return ev.evalBlock(pipeline.fallback, attemptCtx);
        }

        // Re-throw if nothing handles it
        throw e;
      }
      throw e;
    }
  }
}

function createAttemptFunction(
  pipeline: AttemptPipeline,
  ev: Evaluator,
  callerCtx: KtgContext,
): KtgNative {
  return {
    type: 'native!',
    name: 'attempt-pipeline',
    arity: 1,
    fn: (args: KtgValue[]) => {
      return executeAttempt(pipeline, args[0], ev, callerCtx);
    },
  };
}

function bindBlock(block: KtgBlock, targetCtx: KtgContext): void {
  for (let i = 0; i < block.values.length; i++) {
    const v = block.values[i];
    if ((v.type === 'word!' || v.type === 'set-word!' || v.type === 'get-word!') && targetCtx.has(v.name)) {
      (v as any).bound = targetCtx;
    }
    // Recurse into nested blocks
    if (v.type === 'block!' || v.type === 'paren!') {
      bindBlock(v as KtgBlock, targetCtx);
    }
  }
}

function composeBlock(block: KtgBlock, ev: Evaluator, ctx: KtgContext): KtgValue[] {
  const result: KtgValue[] = [];
  for (const v of block.values) {
    if (v.type === 'paren!') {
      const inner: KtgBlock = { type: 'block!', values: v.values };
      result.push(ev.evalBlock(inner, ctx));
    } else if (v.type === 'block!') {
      result.push({ type: 'block!', values: composeBlock(v, ev, ctx) });
    } else {
      result.push(v);
    }
  }
  return result;
}
