import { KtgContext } from './context';
import {
  KtgValue, KtgBlock,
  NONE, KtgError, BreakSignal,
  numVal, valueToString,
} from './values';
import type { Evaluator } from './evaluator';

type LoopRefinement = 'none' | 'collect' | 'fold' | 'partition';

interface LoopConfig {
  vars: string[];
  source: 'range' | 'series';
  // For range
  from?: number;
  to?: number;
  step?: number;
  // For series
  series?: KtgBlock;
  // Guard
  guard?: KtgBlock;
  // Body
  body: KtgBlock;
}

export function evalLoop(
  block: KtgBlock,
  refinement: LoopRefinement,
  evaluator: Evaluator,
  ctx: KtgContext,
): KtgValue {
  const config = parseDialect(block, evaluator, ctx);
  return executeLoop(config, refinement, evaluator, ctx);
}

function parseDialect(block: KtgBlock, evaluator: Evaluator, ctx: KtgContext): LoopConfig {
  const vals = block.values;
  let i = 0;

  let vars: string[] = [];
  let source: 'range' | 'series' = 'range';
  let from = 1;
  let to = 0;
  let step = 1;
  let series: KtgBlock | undefined;
  let guard: KtgBlock | undefined;
  let body: KtgBlock | undefined;

  // Parse dialect keywords
  while (i < vals.length) {
    const v = vals[i];

    if (v.type === 'word!' && v.name === 'for') {
      i++;
      // Expect block of variable names
      const varBlock = vals[i];
      if (varBlock && varBlock.type === 'block!') {
        vars = varBlock.values
          .filter(v => v.type === 'word!')
          .map(v => (v as any).name);
        i++;
      }
      continue;
    }

    if (v.type === 'word!' && v.name === 'in') {
      i++;
      source = 'series';
      // Evaluate the source expression
      const srcVal = vals[i];
      if (srcVal) {
        if (srcVal.type === 'block!') {
          series = srcVal;
        } else {
          // Evaluate the expression
          const [result] = evaluator.evalNext(vals, i, ctx);
          if (result.type === 'block!') series = result;
        }
        i++;
      }
      continue;
    }

    if (v.type === 'word!' && v.name === 'from') {
      i++;
      source = 'range';
      if (vals[i]) {
        const [result] = evaluator.evalNext(vals, i, ctx);
        from = numVal(result);
        i++;
      }
      continue;
    }

    if (v.type === 'word!' && v.name === 'to') {
      i++;
      if (vals[i]) {
        const [result] = evaluator.evalNext(vals, i, ctx);
        to = numVal(result);
        i++;
      }
      continue;
    }

    if (v.type === 'word!' && v.name === 'by') {
      i++;
      if (vals[i]) {
        const [result] = evaluator.evalNext(vals, i, ctx);
        step = numVal(result);
        i++;
      }
      continue;
    }

    if (v.type === 'word!' && v.name === 'when') {
      i++;
      if (vals[i] && vals[i].type === 'block!') {
        guard = vals[i] as KtgBlock;
        i++;
      }
      continue;
    }

    // Last block is the body
    if (v.type === 'block!') {
      body = v;
      i++;
      continue;
    }

    i++;
  }

  if (!body) {
    // If no explicit body found, use implicit body (collect just the values)
    body = { type: 'block!', values: [] };
  }

  // If no vars specified, default to ['it']
  if (vars.length === 0) vars = ['it'];

  // Auto-detect step direction
  if (source === 'range' && to < from && step > 0) step = -step;

  return { vars, source, from, to, step, series, guard, body };
}

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

  // For fold, first var is the accumulator — remaining vars are iteration vars
  const isFold = refinement === 'fold';
  const iterVars = isFold ? config.vars.slice(1) : config.vars;

  const iterate = (values: KtgValue[][]): void => {
    for (const tuple of values) {
      // Fold: first iteration skips body, inits accumulator
      if (isFold && isFirstIteration) {
        isFirstIteration = false;
        accumulator = tuple[0] ?? NONE;
        continue;
      }

      // Bind iteration variables from tuple
      for (let j = 0; j < iterVars.length; j++) {
        parentCtx.set(iterVars[j], tuple[j] ?? NONE);
      }

      // Fold: bind accumulator to first var
      if (isFold && accumulator !== null) {
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
      const stride = isFold ? Math.max(1, iterVars.length) : config.vars.length;
      for (let i = 0; i < items.length; i += stride) {
        const tuple: KtgValue[] = [];
        for (let j = 0; j < stride; j++) {
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
