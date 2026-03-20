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
