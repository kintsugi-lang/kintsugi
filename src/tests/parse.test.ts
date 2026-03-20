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
    expect(eval_('parse [1 2 "a" 3] [to string! string! integer!]')).toEqual({ type: 'logic!', value: true });
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
  test('type-first argument order', () => {
    const ev = new Evaluator();
    ev.evalString("user!: @type ['name string! 'age integer!]");
    expect(ev.evalString('is? user! [name "Alice" age 25]')).toEqual({ type: 'logic!', value: true });
    expect(ev.evalString('is? user! [name "Alice"]')).toEqual({ type: 'logic!', value: false });
  });

  test('works with built-in type names', () => {
    expect(eval_('is? integer! 42')).toEqual({ type: 'logic!', value: true });
    expect(eval_('is? string! 42')).toEqual({ type: 'logic!', value: false });
  });

  test('works with raw parse rule blocks', () => {
    expect(eval_("is? ['x integer!] [x 10]")).toEqual({ type: 'logic!', value: true });
  });
});

describe('parse string — basic', () => {
  test('string parsing works', () => {
    expect(eval_('parse "hello" [some alpha]')).toEqual({ type: 'logic!', value: true });
  });
});
