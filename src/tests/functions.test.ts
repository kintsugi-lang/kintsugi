import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('user-defined functions', () => {
  test('simple function', () => {
    expect(eval_('add: function [a b] [a + b] add 3 4')).toEqual({ type: 'integer!', value: 7 });
  });

  test('function with no args', () => {
    expect(eval_('greet: function [] [42] greet')).toEqual({ type: 'integer!', value: 42 });
  });

  test('get-word retrieves function without calling', () => {
    const ev = new Evaluator();
    ev.evalString('add: function [a b] [a + b]');
    const fn = ev.evalString(':add');
    expect(fn.type).toBe('function!');
  });

  test('get-word allows indirect calling', () => {
    expect(eval_('add: function [a b] [a + b] op: :add op 3 4')).toEqual({ type: 'integer!', value: 7 });
  });

  test('closure captures environment', () => {
    expect(eval_(
      'make-adder: function [n] [function [x] [x + n]] add5: make-adder 5 add5 10'
    )).toEqual({ type: 'integer!', value: 15 });
  });

  test('return exits early', () => {
    expect(eval_(
      'f: function [x] [if x > 0 [return x] 0] f 5'
    )).toEqual({ type: 'integer!', value: 5 });
  });

  test('return from else branch', () => {
    expect(eval_(
      'f: function [x] [if x > 0 [return x] 0] f -1'
    )).toEqual({ type: 'integer!', value: 0 });
  });

  test('recursive function', () => {
    expect(eval_(
      'fact: function [n] [either n = 0 [1] [n * fact (n - 1)]] fact 5'
    )).toEqual({ type: 'integer!', value: 120 });
  });

  test('function body sees globals', () => {
    const ev = new Evaluator();
    ev.evalString('x: 10');
    ev.evalString('f: function [y] [x + y]');
    expect(ev.evalString('f 5')).toEqual({ type: 'integer!', value: 15 });
  });
});
