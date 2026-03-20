import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('to — existing conversions', () => {
  test('to integer! from string', () => {
    expect(eval_('to integer! "42"')).toEqual({ type: 'integer!', value: 42 });
  });

  test('to integer! from float (truncates)', () => {
    expect(eval_('to integer! 3.99')).toEqual({ type: 'integer!', value: 3 });
  });

  test('to float! from string', () => {
    expect(eval_('to float! "3.14"')).toEqual({ type: 'float!', value: 3.14 });
  });

  test('to float! from integer', () => {
    expect(eval_('to float! 7')).toEqual({ type: 'float!', value: 7 });
  });

  test('to string! from integer', () => {
    expect(eval_('to string! 42')).toEqual({ type: 'string!', value: '42' });
  });

  test('to string! from logic', () => {
    expect(eval_('to string! true')).toEqual({ type: 'string!', value: 'true' });
  });

  test('to logic! from truthy', () => {
    expect(eval_('to logic! 1')).toEqual({ type: 'logic!', value: true });
  });

  test('to word! from string', () => {
    expect(eval_('to word! "hello"')).toEqual({ type: 'word!', name: 'hello' });
  });

  test('to set-word! from word', () => {
    expect(eval_("to set-word! 'x")).toEqual({ type: 'set-word!', name: 'x' });
  });

  test('to block! wraps value', () => {
    const result = eval_('to block! 42');
    expect(result.type).toBe('block!');
    if (result.type === 'block!') {
      expect(result.values).toEqual([{ type: 'integer!', value: 42 }]);
    }
  });
});

describe('to — new conversions', () => {
  test('to integer! from logic', () => {
    expect(eval_('to integer! true')).toEqual({ type: 'integer!', value: 1 });
    expect(eval_('to integer! false')).toEqual({ type: 'integer!', value: 0 });
  });

  test('to float! from logic', () => {
    expect(eval_('to float! true')).toEqual({ type: 'float!', value: 1 });
    expect(eval_('to float! false')).toEqual({ type: 'float!', value: 0 });
  });

  test('codepoint from string', () => {
    expect(eval_('codepoint "A"')).toEqual({ type: 'integer!', value: 65 });
  });

  test('from-codepoint to string', () => {
    expect(eval_('from-codepoint 65')).toEqual({ type: 'string!', value: 'A' });
  });

  test('to string! from block (space-separated)', () => {
    expect(eval_('to string! [1 2 3]')).toEqual({ type: 'string!', value: '1 2 3' });
  });

  test('#"A" is sugar for string "A"', () => {
    expect(eval_('#"A"')).toEqual({ type: 'string!', value: 'A' });
  });

  test('to word! from lit-word', () => {
    expect(eval_("to word! 'hello")).toEqual({ type: 'word!', name: 'hello' });
  });

  test('to lit-word! from word value', () => {
    const ev = new Evaluator();
    ev.evalString('w: to word! "test"');
    // w is a word! value, but when evaluated it would try to look up "test"
    // Instead, get-word to avoid evaluation
    expect(ev.evalString('to lit-word! :w')).toEqual({ type: 'lit-word!', name: 'test' });
  });
});

describe('join — improvements', () => {
  test('join two strings', () => {
    expect(eval_('join "hello" " world"')).toEqual({ type: 'string!', value: 'hello world' });
  });

  test('join string and integer', () => {
    expect(eval_('join "count: " 42')).toEqual({ type: 'string!', value: 'count: 42' });
  });

  test('join string and block (rejoin the block)', () => {
    expect(eval_('join "hello" [" " "world"]')).toEqual({ type: 'string!', value: 'hello world' });
  });

  test('join string and block with mixed types', () => {
    expect(eval_('join "val: " [1 " + " 2]')).toEqual({ type: 'string!', value: 'val: 1 + 2' });
  });
});
