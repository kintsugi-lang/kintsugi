import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

describe('scalars', () => {
  test('integer', () => {
    expect(eval_('42')).toEqual({ type: 'integer!', value: 42 });
  });

  test('float', () => {
    expect(eval_('3.14')).toEqual({ type: 'float!', value: 3.14 });
  });

  test('string', () => {
    expect(eval_('"hello"')).toEqual({ type: 'string!', value: 'hello' });
  });

  test('logic', () => {
    expect(eval_('true')).toEqual({ type: 'logic!', value: true });
    expect(eval_('false')).toEqual({ type: 'logic!', value: false });
  });

  test('none', () => {
    expect(eval_('none')).toEqual({ type: 'none!' });
  });
});

describe('set-word and word lookup', () => {
  test('bind and retrieve', () => {
    const ev = new Evaluator();
    ev.evalString('x: 42');
    expect(ev.evalString('x')).toEqual({ type: 'integer!', value: 42 });
  });

  test('set-word returns the value', () => {
    expect(eval_('x: 42')).toEqual({ type: 'integer!', value: 42 });
  });

  test('chain assignment', () => {
    const ev = new Evaluator();
    ev.evalString('x: 42');
    expect(ev.evalString('x')).toEqual({ type: 'integer!', value: 42 });
  });

  test('multiple expressions, last wins', () => {
    expect(eval_('1 2 3')).toEqual({ type: 'integer!', value: 3 });
  });
});

describe('get-word', () => {
  test('returns value without calling', () => {
    const ev = new Evaluator();
    ev.evalString('x: 42');
    expect(ev.evalString(':x')).toEqual({ type: 'integer!', value: 42 });
  });

  test('get-word on function returns the function', () => {
    const ev = new Evaluator();
    const result = ev.evalString(':print');
    expect(result.type).toBe('native!');
  });
});

describe('lit-word', () => {
  test('returns self', () => {
    expect(eval_("'hello")).toEqual({ type: 'lit-word!', name: 'hello' });
  });
});

describe('arithmetic operators', () => {
  test('addition', () => {
    expect(eval_('2 + 3')).toEqual({ type: 'integer!', value: 5 });
  });

  test('subtraction', () => {
    expect(eval_('10 - 3')).toEqual({ type: 'integer!', value: 7 });
  });

  test('multiplication', () => {
    expect(eval_('4 * 5')).toEqual({ type: 'integer!', value: 20 });
  });

  test('division always produces float', () => {
    expect(eval_('10 / 3')).toEqual({ type: 'float!', value: 10 / 3 });
    expect(eval_('10 / 2')).toEqual({ type: 'float!', value: 5 });
  });

  test('left-to-right (no precedence)', () => {
    expect(eval_('2 + 3 * 4')).toEqual({ type: 'integer!', value: 20 });
  });

  test('parens override order', () => {
    expect(eval_('2 + (3 * 4)')).toEqual({ type: 'integer!', value: 14 });
  });

  test('float arithmetic', () => {
    expect(eval_('1.5 + 2.5')).toEqual({ type: 'float!', value: 4 });
  });

  test('string concatenation with +', () => {
    expect(eval_('"hello" + " world"')).toEqual({ type: 'string!', value: 'hello world' });
  });
});

describe('comparison operators', () => {
  test('equal', () => {
    expect(eval_('5 = 5')).toEqual({ type: 'logic!', value: true });
    expect(eval_('5 = 3')).toEqual({ type: 'logic!', value: false });
  });

  test('not equal', () => {
    expect(eval_('5 <> 3')).toEqual({ type: 'logic!', value: true });
  });

  test('less than', () => {
    expect(eval_('3 < 5')).toEqual({ type: 'logic!', value: true });
  });

  test('greater than', () => {
    expect(eval_('5 > 3')).toEqual({ type: 'logic!', value: true });
  });

  test('less than or equal', () => {
    expect(eval_('3 <= 3')).toEqual({ type: 'logic!', value: true });
  });

  test('greater than or equal', () => {
    expect(eval_('5 >= 5')).toEqual({ type: 'logic!', value: true });
  });
});

describe('blocks are inert', () => {
  test('block returns as data', () => {
    const result = eval_('[1 + 2]');
    expect(result.type).toBe('block!');
    if (result.type === 'block!') {
      expect(result.values).toHaveLength(3);
      expect(result.values[0]).toEqual({ type: 'integer!', value: 1 });
    }
  });
});

describe('parens evaluate', () => {
  test('paren evaluates contents', () => {
    expect(eval_('(1 + 2)')).toEqual({ type: 'integer!', value: 3 });
  });
});

describe('set-word with infix', () => {
  test('set-word captures full infix expression', () => {
    const ev = new Evaluator();
    ev.evalString('x: 2 + 3');
    expect(ev.evalString('x')).toEqual({ type: 'integer!', value: 5 });
  });
});

describe('undefined word error', () => {
  test('throws on undefined word', () => {
    expect(() => eval_('undefined-word')).toThrow('has no value');
  });
});
