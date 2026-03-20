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
  'path!', 'block!', 'paren!', 'map!', 'context!', 'function!',
  'native!', 'op!', 'type!', 'operator!',
]);

const CHAR_CLASSES: Record<string, (ch: string) => boolean> = {
  'alpha': (ch) => /^[a-zA-Z]$/.test(ch),
  'digit': (ch) => /^[0-9]$/.test(ch),
  'alnum': (ch) => /^[a-zA-Z0-9]$/.test(ch),
  'space': (ch) => /^\s$/.test(ch),
  'upper': (ch) => /^[A-Z]$/.test(ch),
  'lower': (ch) => /^[a-z]$/.test(ch),
};

// --- Input abstraction ---

type ParseInput =
  | { mode: 'block'; values: KtgValue[] }
  | { mode: 'string'; str: string };

function inputLength(input: ParseInput): number {
  return input.mode === 'block' ? input.values.length : input.str.length;
}

function captureSlice(input: ParseInput, start: number, end: number): KtgValue {
  if (input.mode === 'block') {
    if (end - start === 1) return input.values[start];
    return { type: 'block!', values: input.values.slice(start, end) };
  }
  return { type: 'string!', value: input.str.slice(start, end) };
}

// --- Public API ---

export function parseBlock(
  inputBlock: KtgBlock,
  rules: KtgBlock,
  ctx: KtgContext,
  evaluator: Evaluator,
): boolean {
  const input: ParseInput = { mode: 'block', values: inputBlock.values };
  const result = matchSequence(input, 0, rules.values, ctx, evaluator, []);
  return result !== null && result === inputLength(input);
}

export function parseString(
  inputStr: string,
  rules: KtgBlock,
  ctx: KtgContext,
  evaluator: Evaluator,
): boolean {
  const input: ParseInput = { mode: 'string', str: inputStr };
  const result = matchSequence(input, 0, rules.values, ctx, evaluator, []);
  return result !== null && result === inputLength(input);
}

// --- Core engine ---

function matchSequence(
  input: ParseInput,
  iPos: number,
  ruleValues: KtgValue[],
  ctx: KtgContext,
  evaluator: Evaluator,
  collectStack: KtgValue[][],
): number | null {
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
  input: ParseInput,
  iPos: number,
  rules: KtgValue[],
  ctx: KtgContext,
  evaluator: Evaluator,
  collectStack: KtgValue[][],
): number | null {
  let rPos = 0;
  const len = inputLength(input);

  while (rPos < rules.length) {
    const rule = rules[rPos];

    // Set-word: capture
    if (rule.type === 'set-word!') {
      const captureName = rule.name;
      rPos++;
      if (rPos >= rules.length) return null;

      // Check if next is collect
      if (rules[rPos].type === 'word!' && (rules[rPos] as any).name === 'collect') {
        const result = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack);
        if (result === null) return null;
        [iPos, rPos] = result;
        const collected = ctx.get('__parse_collect_result');
        if (collected) ctx.set(captureName, collected);
        continue;
      }

      const startPos = iPos;
      const result = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack);
      if (result === null) return null;
      [iPos, rPos] = result;
      if (iPos > startPos) {
        ctx.set(captureName, captureSlice(input, startPos, iPos));
      }
      continue;
    }

    // Integer: repeat count (N rule or N M rule) — only in sequence context
    if (rule.type === 'integer!' && rPos + 1 < rules.length) {
      const count = rule.value;
      if (rPos + 2 < rules.length && rules[rPos + 1].type === 'integer!') {
        const maxCount = (rules[rPos + 1] as any).value;
        rPos += 2;
        const result = matchRepeat(input, iPos, rules, rPos, ctx, evaluator, collectStack, count, maxCount);
        if (result === null) return null;
        [iPos, rPos] = result;
        continue;
      }
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
    const result = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack);
    if (result === null) return null;
    [iPos, rPos] = result;
  }
  return iPos;
}

function matchOneRule(
  input: ParseInput,
  iPos: number,
  rules: KtgValue[],
  rPos: number,
  ctx: KtgContext,
  evaluator: Evaluator,
  collectStack: KtgValue[][],
): [number, number] | null {
  const rule = rules[rPos];
  const len = inputLength(input);

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

  // --- Block-only rules ---
  if (input.mode === 'block') {
    // Lit-word: match literal word in input
    if (rule.type === 'lit-word!') {
      if (iPos >= len) return null;
      const val = input.values[iPos];
      if (val.type === 'word!' && val.name === rule.name) return [iPos + 1, rPos + 1];
      if (val.type === 'lit-word!' && val.name === rule.name) return [iPos + 1, rPos + 1];
      return null;
    }

    // String literal in block mode: match exact string value
    if (rule.type === 'string!') {
      if (iPos >= len) return null;
      const val = input.values[iPos];
      if (val.type === 'string!' && val.value === rule.value) return [iPos + 1, rPos + 1];
      return null;
    }

    // Integer literal in block mode: match exact integer value
    if (rule.type === 'integer!') {
      if (iPos >= len) return null;
      const val = input.values[iPos];
      if (val.type === 'integer!' && val.value === rule.value) return [iPos + 1, rPos + 1];
      return null;
    }
  }

  // --- String-only rules ---
  if (input.mode === 'string') {
    // String literal: match substring
    if (rule.type === 'string!') {
      const target = rule.value;
      if (iPos + target.length > len) return null;
      if (input.str.slice(iPos, iPos + target.length) === target) {
        return [iPos + target.length, rPos + 1];
      }
      return null;
    }
  }

  // Word: keyword or composable rule
  if (rule.type === 'word!') {
    const name = rule.name;

    // String mode: check character classes first
    if (input.mode === 'string' && CHAR_CLASSES[name]) {
      if (iPos >= len) return null;
      return CHAR_CLASSES[name](input.str[iPos]) ? [iPos + 1, rPos + 1] : null;
    }

    switch (name) {
      case 'end':
        return iPos >= len ? [iPos, rPos + 1] : null;

      case 'skip':
        return iPos < len ? [iPos + 1, rPos + 1] : null;

      case 'fail':
        return null;

      case 'some': {
        rPos++;
        let pos = iPos;
        let matched = 0;
        while (true) {
          const r = matchOneRule(input, pos, rules, rPos, ctx, evaluator, collectStack);
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
          const r = matchOneRule(input, pos, rules, rPos, ctx, evaluator, collectStack);
          if (r === null || r[0] === pos) break;
          pos = r[0];
        }
        return [pos, rPos + 1];
      }

      case 'opt': {
        rPos++;
        const r = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack);
        return r !== null ? [r[0], rPos + 1] : [iPos, rPos + 1];
      }

      case 'not': {
        rPos++;
        const r = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack);
        return r === null ? [iPos, rPos + 1] : null;
      }

      case 'ahead': {
        rPos++;
        const r = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack);
        return r !== null ? [iPos, rPos + 1] : null;
      }

      case 'to': {
        rPos++;
        for (let scan = iPos; scan < len; scan++) {
          const r = matchOneRule(input, scan, rules, rPos, ctx, evaluator, collectStack);
          if (r !== null) return [scan, rPos + 1];
        }
        return null;
      }

      case 'thru': {
        rPos++;
        for (let scan = iPos; scan < len; scan++) {
          const r = matchOneRule(input, scan, rules, rPos, ctx, evaluator, collectStack);
          if (r !== null) return [r[0], rPos + 1];
        }
        return null;
      }

      case 'into': {
        // Only works in block mode
        if (input.mode !== 'block') return null;
        rPos++;
        if (iPos >= len) return null;
        const val = input.values[iPos];
        if (val.type !== 'block!') return null;
        const subRule = rules[rPos];
        if (!subRule || subRule.type !== 'block!') return null;
        const subInput: ParseInput = { mode: 'block', values: val.values };
        const subResult = matchSequence(subInput, 0, subRule.values, ctx, evaluator, collectStack);
        if (subResult === null || subResult !== val.values.length) return null;
        return [iPos + 1, rPos + 1];
      }

      case 'quote': {
        if (input.mode !== 'block') return null;
        rPos++;
        if (rPos >= rules.length || iPos >= len) return null;
        const expected = rules[rPos];
        const actual = input.values[iPos];
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
        ctx.set('__parse_collect_result', { type: 'block!', values: collected });
        return [r, rPos + 1];
      }

      case 'keep': {
        rPos++;
        const startPos = iPos;
        const r = matchOneRule(input, iPos, rules, rPos, ctx, evaluator, collectStack);
        if (r === null) return null;
        if (collectStack.length > 0) {
          const bucket = collectStack[collectStack.length - 1];
          if (input.mode === 'block') {
            for (let k = startPos; k < r[0]; k++) {
              bucket.push(input.values[k]);
            }
          } else {
            bucket.push({ type: 'string!', value: input.str.slice(startPos, r[0]) });
          }
        }
        return [r[0], rPos + 1];
      }

      default: {
        // Block mode: type match (word ending in !)
        if (input.mode === 'block' && name.endsWith('!') && TYPE_NAMES.has(name)) {
          if (iPos >= len) return null;
          return input.values[iPos].type === name ? [iPos + 1, rPos + 1] : null;
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
  input: ParseInput,
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
    const r = matchOneRule(input, pos, rules, rPos, ctx, evaluator, collectStack);
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
    ? [rules]
    : alternatives;
}
