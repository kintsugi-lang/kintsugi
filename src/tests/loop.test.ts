import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('simple loop', () => {
  test('loop with break', () => {
    expect(eval_('x: 0 loop [x: x + 1 if x = 3 [break]] x')).toEqual({ type: 'integer!', value: 3 });
  });
});

describe('loop dialect', () => {
  test('for-in with side effects', () => {
    const ev = new Evaluator();
    ev.evalString('sum: 0 loop [for [x] in [1 2 3] [sum: sum + x]]');
    expect(ev.evalString('sum')).toEqual({ type: 'integer!', value: 6 });
  });

  test('from-to range', () => {
    const ev = new Evaluator();
    ev.evalString('sum: 0 loop [for [n] from 1 to 5 [sum: sum + n]]');
    expect(ev.evalString('sum')).toEqual({ type: 'integer!', value: 15 });
  });
});

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
