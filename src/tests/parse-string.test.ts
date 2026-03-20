import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('parse string — basic', () => {
  test('empty rule matches empty string', () => {
    expect(eval_('parse "" []')).toEqual({ type: 'logic!', value: true });
  });

  test('string literal matches exactly', () => {
    expect(eval_('parse "hello" ["hello"]')).toEqual({ type: 'logic!', value: true });
  });

  test('string literal mismatch', () => {
    expect(eval_('parse "hello" ["world"]')).toEqual({ type: 'logic!', value: false });
  });

  test('partial match fails', () => {
    expect(eval_('parse "hello" ["hell"]')).toEqual({ type: 'logic!', value: false });
  });

  test('sequence of literals', () => {
    expect(eval_('parse "hello world" ["hello" " " "world"]')).toEqual({ type: 'logic!', value: true });
  });

  test('skip matches one character', () => {
    expect(eval_('parse "a" [skip]')).toEqual({ type: 'logic!', value: true });
  });

  test('skip on multi-char fails without more', () => {
    expect(eval_('parse "ab" [skip]')).toEqual({ type: 'logic!', value: false });
  });

  test('end matches at end', () => {
    expect(eval_('parse "" [end]')).toEqual({ type: 'logic!', value: true });
  });
});

describe('parse string — character classes', () => {
  test('alpha matches letter', () => {
    expect(eval_('parse "a" [alpha]')).toEqual({ type: 'logic!', value: true });
  });

  test('alpha fails on digit', () => {
    expect(eval_('parse "1" [alpha]')).toEqual({ type: 'logic!', value: false });
  });

  test('digit matches digit', () => {
    expect(eval_('parse "5" [digit]')).toEqual({ type: 'logic!', value: true });
  });

  test('some alpha matches word', () => {
    expect(eval_('parse "hello" [some alpha]')).toEqual({ type: 'logic!', value: true });
  });

  test('some digit matches number', () => {
    expect(eval_('parse "12345" [some digit]')).toEqual({ type: 'logic!', value: true });
  });

  test('alnum matches mixed', () => {
    expect(eval_('parse "abc123" [some alnum]')).toEqual({ type: 'logic!', value: true });
  });

  test('space matches whitespace', () => {
    expect(eval_('parse " " [space]')).toEqual({ type: 'logic!', value: true });
  });

  test('upper matches uppercase', () => {
    expect(eval_('parse "A" [upper]')).toEqual({ type: 'logic!', value: true });
    expect(eval_('parse "a" [upper]')).toEqual({ type: 'logic!', value: false });
  });

  test('lower matches lowercase', () => {
    expect(eval_('parse "a" [lower]')).toEqual({ type: 'logic!', value: true });
    expect(eval_('parse "A" [lower]')).toEqual({ type: 'logic!', value: false });
  });
});

describe('parse string — combinators', () => {
  test('some and sequence', () => {
    expect(eval_('parse "abc123" [some alpha some digit]')).toEqual({ type: 'logic!', value: true });
  });

  test('any matches zero', () => {
    expect(eval_('parse "123" [any alpha some digit]')).toEqual({ type: 'logic!', value: true });
  });

  test('opt', () => {
    expect(eval_('parse "123" [opt alpha some digit]')).toEqual({ type: 'logic!', value: true });
  });

  test('alternatives', () => {
    expect(eval_('parse "abc" [some alpha | some digit]')).toEqual({ type: 'logic!', value: true });
    expect(eval_('parse "123" [some alpha | some digit]')).toEqual({ type: 'logic!', value: true });
  });

  test('exact count', () => {
    expect(eval_('parse "aaa" [3 alpha]')).toEqual({ type: 'logic!', value: true });
    expect(eval_('parse "aa" [3 alpha]')).toEqual({ type: 'logic!', value: false });
  });

  test('not', () => {
    expect(eval_('parse "1" [not alpha digit]')).toEqual({ type: 'logic!', value: true });
  });

  test('ahead', () => {
    expect(eval_('parse "a" [ahead alpha alpha]')).toEqual({ type: 'logic!', value: true });
  });
});

describe('parse string — extraction', () => {
  test('capture with set-word', () => {
    const ev = new Evaluator();
    ev.evalString('parse "hello world" [greeting: some alpha " " name: some alpha]');
    expect(ev.evalString('greeting')).toEqual({ type: 'string!', value: 'hello' });
    expect(ev.evalString('name')).toEqual({ type: 'string!', value: 'world' });
  });

  test('capture digits', () => {
    const ev = new Evaluator();
    ev.evalString('parse "age:25" ["age:" num: some digit]');
    expect(ev.evalString('num')).toEqual({ type: 'string!', value: '25' });
  });
});

describe('parse string — scanning', () => {
  test('thru scans past match', () => {
    expect(eval_('parse "hello world" [thru " " some alpha]')).toEqual({ type: 'logic!', value: true });
  });

  test('to scans to match', () => {
    expect(eval_('parse "hello world" [to " " " " some alpha]')).toEqual({ type: 'logic!', value: true });
  });
});

describe('parse string — composable rules', () => {
  test('word resolves to sub-rule', () => {
    const ev = new Evaluator();
    ev.evalString('word-chars: [some alpha]');
    expect(ev.evalString('parse "hello" word-chars')).toEqual({ type: 'logic!', value: true });
  });
});

describe('parse string — email example from spec', () => {
  test('parse email', () => {
    const ev = new Evaluator();
    ev.evalString(`parse "user@example.com" [
      name: some [alpha | digit | "."]
      "@"
      domain: some [alpha | digit | "." | "-"]
    ]`);
    expect(ev.evalString('name')).toEqual({ type: 'string!', value: 'user' });
    expect(ev.evalString('domain')).toEqual({ type: 'string!', value: 'example.com' });
  });
});
