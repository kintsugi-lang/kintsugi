import { describe, test, expect } from 'bun:test';
import { Evaluator } from '@/evaluator';

const eval_ = (input: string) => {
  const ev = new Evaluator();
  return ev.evalString(input);
};

const evalWith = (input: string) => {
  const ev = new Evaluator();
  const result = ev.evalString(input);
  return { result, output: ev.output };
};

describe('output', () => {
  test('print captures output and returns none', () => {
    const { result, output } = evalWith('print 42');
    expect(result).toEqual({ type: 'none!' });
    expect(output).toEqual(['42']);
  });

  test('probe captures output and returns the value', () => {
    const { result, output } = evalWith('probe 42');
    expect(result).toEqual({ type: 'integer!', value: 42 });
    expect(output).toEqual(['42']);
  });
});

describe('control flow', () => {
  test('if true evaluates block', () => {
    expect(eval_('if true [42]')).toEqual({ type: 'integer!', value: 42 });
  });

  test('if false returns none', () => {
    expect(eval_('if false [42]')).toEqual({ type: 'none!' });
  });

  test('either true', () => {
    expect(eval_('either true [1] [2]')).toEqual({ type: 'integer!', value: 1 });
  });

  test('either false', () => {
    expect(eval_('either false [1] [2]')).toEqual({ type: 'integer!', value: 2 });
  });

  test('not', () => {
    expect(eval_('not true')).toEqual({ type: 'logic!', value: false });
    expect(eval_('not false')).toEqual({ type: 'logic!', value: true });
    expect(eval_('not none')).toEqual({ type: 'logic!', value: true });
  });

  test('loop with break', () => {
    expect(eval_('x: 0 loop [x: x + 1 if x = 5 [break]] x')).toEqual({ type: 'integer!', value: 5 });
  });
});

describe('logical ops', () => {
  test('and short-circuits', () => {
    expect(eval_('true and true')).toEqual({ type: 'logic!', value: true });
    expect(eval_('false and true')).toEqual({ type: 'logic!', value: false });
  });

  test('or short-circuits', () => {
    expect(eval_('false or true')).toEqual({ type: 'logic!', value: true });
    expect(eval_('true or false')).toEqual({ type: 'logic!', value: true });
  });
});

describe('block operations', () => {
  test('length?', () => {
    expect(eval_('length? [1 2 3]')).toEqual({ type: 'integer!', value: 3 });
  });

  test('empty?', () => {
    expect(eval_('empty? []')).toEqual({ type: 'logic!', value: true });
    expect(eval_('empty? [1]')).toEqual({ type: 'logic!', value: false });
  });

  test('first', () => {
    expect(eval_('first [10 20 30]')).toEqual({ type: 'integer!', value: 10 });
  });

  test('second', () => {
    expect(eval_('second [10 20 30]')).toEqual({ type: 'integer!', value: 20 });
  });

  test('last', () => {
    expect(eval_('last [10 20 30]')).toEqual({ type: 'integer!', value: 30 });
  });

  test('pick', () => {
    expect(eval_('pick [10 20 30] 2')).toEqual({ type: 'integer!', value: 20 });
  });

  test('copy returns new block', () => {
    const ev = new Evaluator();
    ev.evalString('a: [1 2 3]');
    ev.evalString('b: copy a');
    ev.evalString('append b 4');
    expect(ev.evalString('length? a')).toEqual({ type: 'integer!', value: 3 });
    expect(ev.evalString('length? b')).toEqual({ type: 'integer!', value: 4 });
  });

  test('append', () => {
    const ev = new Evaluator();
    ev.evalString('a: [1 2]');
    ev.evalString('append a 3');
    expect(ev.evalString('length? a')).toEqual({ type: 'integer!', value: 3 });
  });

  test('insert at position', () => {
    const ev = new Evaluator();
    ev.evalString('a: [1 2 3]');
    ev.evalString('insert a 0 1');
    expect(ev.evalString('first a')).toEqual({ type: 'integer!', value: 0 });
    expect(ev.evalString('length? a')).toEqual({ type: 'integer!', value: 4 });
  });

  test('insert at middle', () => {
    const ev = new Evaluator();
    ev.evalString('a: [1 3]');
    ev.evalString('insert a 2 2');
    expect(ev.evalString('pick a 2')).toEqual({ type: 'integer!', value: 2 });
  });

  test('remove from block by position', () => {
    const ev = new Evaluator();
    ev.evalString('a: [10 20 30]');
    ev.evalString('remove a 2');
    expect(ev.evalString('length? a')).toEqual({ type: 'integer!', value: 2 });
    expect(ev.evalString('second a')).toEqual({ type: 'integer!', value: 30 });
  });

  test('select', () => {
    expect(eval_("select [a 1 b 2] 'b")).toEqual({ type: 'integer!', value: 2 });
  });

  test('has? block', () => {
    expect(eval_('has? [1 2 3] 2')).toEqual({ type: 'logic!', value: true });
    expect(eval_('has? [1 2 3] 9')).toEqual({ type: 'logic!', value: false });
  });

  test('has? string', () => {
    expect(eval_('has? "hello world" "world"')).toEqual({ type: 'logic!', value: true });
    expect(eval_('has? "hello" "xyz"')).toEqual({ type: 'logic!', value: false });
  });

  test('index? block', () => {
    expect(eval_('index? [10 20 30] 20')).toEqual({ type: 'integer!', value: 2 });
    expect(eval_('index? [1 2 3] 9')).toEqual({ type: 'none!' });
  });

  test('index? string', () => {
    expect(eval_('index? "hello world" "world"')).toEqual({ type: 'integer!', value: 7 });
    expect(eval_('index? "hello" "xyz"')).toEqual({ type: 'none!' });
  });
});

describe('type operations', () => {
  test('type?', () => {
    expect(eval_('type? 42')).toEqual({ type: 'type!', name: 'integer!' });
    expect(eval_('type? "hi"')).toEqual({ type: 'type!', name: 'string!' });
    expect(eval_('type? true')).toEqual({ type: 'type!', name: 'logic!' });
  });
});

describe('string operations', () => {
  test('join', () => {
    expect(eval_('join "a" "b"')).toEqual({ type: 'string!', value: 'ab' });
  });

  test('rejoin', () => {
    expect(eval_('rejoin ["hello" " " "world"]')).toEqual({ type: 'string!', value: 'hello world' });
  });

  test('trim', () => {
    expect(eval_('trim "  hi  "')).toEqual({ type: 'string!', value: 'hi' });
  });

  test('split', () => {
    const result = eval_('split "a,b,c" ","');
    expect(result.type).toBe('block!');
    if (result.type === 'block!') {
      expect(result.values).toHaveLength(3);
      expect(result.values[0]).toEqual({ type: 'string!', value: 'a' });
    }
  });

  test('uppercase', () => {
    expect(eval_('uppercase "hello"')).toEqual({ type: 'string!', value: 'HELLO' });
  });

  test('lowercase', () => {
    expect(eval_('lowercase "HELLO"')).toEqual({ type: 'string!', value: 'hello' });
  });

  test('replace', () => {
    expect(eval_('replace "hello world" "world" "earth"')).toEqual({ type: 'string!', value: 'hello earth' });
  });
});

describe('math utilities', () => {
  test('min', () => {
    expect(eval_('min 3 7')).toEqual({ type: 'integer!', value: 3 });
  });

  test('max', () => {
    expect(eval_('max 3 7')).toEqual({ type: 'integer!', value: 7 });
  });

  test('abs', () => {
    expect(eval_('abs -5')).toEqual({ type: 'integer!', value: 5 });
  });

  test('negate', () => {
    expect(eval_('negate 5')).toEqual({ type: 'integer!', value: -5 });
  });

  test('round nearest', () => {
    expect(eval_('round 3.7')).toEqual({ type: 'integer!', value: 4 });
    expect(eval_('round 3.2')).toEqual({ type: 'integer!', value: 3 });
  });

  test('round/down truncates toward zero', () => {
    expect(eval_('round/down 3.9')).toEqual({ type: 'integer!', value: 3 });
    expect(eval_('round/down -3.9')).toEqual({ type: 'integer!', value: -3 });
  });

  test('round/up away from zero', () => {
    expect(eval_('round/up 3.2')).toEqual({ type: 'integer!', value: 4 });
    expect(eval_('round/up -3.2')).toEqual({ type: 'integer!', value: -4 });
  });

  test('round on integer division', () => {
    expect(eval_('round/down 10 / 3')).toEqual({ type: 'integer!', value: 3 });
  });

  test('odd?', () => {
    expect(eval_('odd? 3')).toEqual({ type: 'logic!', value: true });
    expect(eval_('odd? 4')).toEqual({ type: 'logic!', value: false });
  });

  test('even?', () => {
    expect(eval_('even? 4')).toEqual({ type: 'logic!', value: true });
    expect(eval_('even? 3')).toEqual({ type: 'logic!', value: false });
  });
});

describe('code-as-data', () => {
  test('do evaluates block', () => {
    expect(eval_('do [1 + 2]')).toEqual({ type: 'integer!', value: 3 });
  });

  test('compose evaluates parens in block', () => {
    const result = eval_('compose [1 (2 + 3) 4]');
    expect(result.type).toBe('block!');
    if (result.type === 'block!') {
      expect(result.values).toHaveLength(3);
      expect(result.values[0]).toEqual({ type: 'integer!', value: 1 });
      expect(result.values[1]).toEqual({ type: 'integer!', value: 5 });
      expect(result.values[2]).toEqual({ type: 'integer!', value: 4 });
    }
  });
});
