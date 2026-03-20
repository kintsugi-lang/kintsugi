import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('context', () => {
  test('create and access fields', () => {
    const ev = new Evaluator();
    ev.evalString('point: context [x: 10 y: 20]');
    expect(ev.evalString('point/x')).toEqual({ type: 'integer!', value: 10 });
    expect(ev.evalString('point/y')).toEqual({ type: 'integer!', value: 20 });
  });

  test('set-path assignment', () => {
    const ev = new Evaluator();
    ev.evalString('point: context [x: 10 y: 20]');
    ev.evalString('point/x: 30');
    expect(ev.evalString('point/x')).toEqual({ type: 'integer!', value: 30 });
  });

  test('context with computed values', () => {
    const ev = new Evaluator();
    ev.evalString('p: context [x: 2 + 3 y: x * 2]');
    expect(ev.evalString('p/x')).toEqual({ type: 'integer!', value: 5 });
    expect(ev.evalString('p/y')).toEqual({ type: 'integer!', value: 10 });
  });

  test('type? returns context!', () => {
    const ev = new Evaluator();
    ev.evalString('p: context [x: 1]');
    expect(ev.evalString('type? p')).toEqual({ type: 'type!', name: 'context!' });
  });
});
