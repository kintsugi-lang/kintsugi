import { describe, test, expect } from 'bun:test';
import { parseString } from '@/helpers';
import { astToValue, isTruthy, typeOf, valueToString, NONE, KtgValue } from '@/evaluator/values';
import { AstNode } from '@types';

const convert = (input: string): KtgValue => {
  const ast = parseString(input);
  return astToValue(ast.children[0]);
};

describe('astToValue', () => {
  test('integer', () => {
    const val = convert('42');
    expect(val).toEqual({ type: 'integer!', value: 42 });
  });

  test('negative integer', () => {
    const val = convert('-7');
    expect(val).toEqual({ type: 'integer!', value: -7 });
  });

  test('float', () => {
    const val = convert('3.14');
    expect(val).toEqual({ type: 'float!', value: 3.14 });
  });

  test('string', () => {
    const val = convert('"hello"');
    expect(val).toEqual({ type: 'string!', value: 'hello' });
  });

  test('logic true', () => {
    const val = convert('true');
    expect(val).toEqual({ type: 'logic!', value: true });
  });

  test('logic false', () => {
    const val = convert('false');
    expect(val).toEqual({ type: 'logic!', value: false });
  });

  test('on/off/yes/no are words (resolved to logic at eval time)', () => {
    expect(convert('on')).toEqual({ type: 'word!', name: 'on' });
    expect(convert('off')).toEqual({ type: 'word!', name: 'off' });
    expect(convert('yes')).toEqual({ type: 'word!', name: 'yes' });
    expect(convert('no')).toEqual({ type: 'word!', name: 'no' });
  });

  test('none', () => {
    const val = convert('none');
    expect(val).toEqual({ type: 'none!' });
  });

  test('char', () => {
    const val = convert('#"A"');
    expect(val).toEqual({ type: 'char!', value: 'A' });
  });

  test('pair', () => {
    const val = convert('100x200');
    expect(val).toEqual({ type: 'pair!', x: 100, y: 200 });
  });

  test('tuple', () => {
    const val = convert('1.2.3');
    expect(val).toEqual({ type: 'tuple!', parts: [1, 2, 3] });
  });

  test('money becomes float', () => {
    const val = convert('$19.99');
    expect(val).toEqual({ type: 'float!', value: 19.99 });
  });

  test('date', () => {
    const val = convert('2026-03-15');
    expect(val).toEqual({ type: 'date!', value: '2026-03-15' });
  });

  test('time', () => {
    const val = convert('14:30');
    expect(val).toEqual({ type: 'time!', value: '14:30' });
  });

  test('file', () => {
    const val = convert('%path/to/file');
    expect(val).toEqual({ type: 'file!', value: 'path/to/file' });
  });

  test('url', () => {
    const val = convert('https://example.com');
    expect(val).toEqual({ type: 'url!', value: 'https://example.com' });
  });

  test('email', () => {
    const val = convert('user@example.com');
    expect(val).toEqual({ type: 'email!', value: 'user@example.com' });
  });

  test('word', () => {
    const val = convert('hello');
    expect(val).toEqual({ type: 'word!', name: 'hello' });
  });

  test('set-word', () => {
    const val = convert('name:');
    expect(val).toEqual({ type: 'set-word!', name: 'name' });
  });

  test('get-word', () => {
    const val = convert(':name');
    expect(val).toEqual({ type: 'get-word!', name: 'name' });
  });

  test('lit-word', () => {
    const val = convert("'name");
    expect(val).toEqual({ type: 'lit-word!', name: 'name' });
  });

  test('path', () => {
    const val = convert('obj/field');
    expect(val).toEqual({ type: 'path!', segments: ['obj', 'field'] });
  });

  test('operator', () => {
    const val = convert('+');
    expect(val).toEqual({ type: 'operator!', symbol: '+' });
  });

  test('block (inert)', () => {
    const ast = parseString('[1 2 3]');
    const val = astToValue(ast.children[0]);
    expect(val.type).toBe('block!');
    if (val.type === 'block!') {
      expect(val.values).toHaveLength(3);
      expect(val.values[0]).toEqual({ type: 'integer!', value: 1 });
      expect(val.values[1]).toEqual({ type: 'integer!', value: 2 });
      expect(val.values[2]).toEqual({ type: 'integer!', value: 3 });
    }
  });

  test('paren', () => {
    const ast = parseString('(1 + 2)');
    const val = astToValue(ast.children[0]);
    expect(val.type).toBe('paren!');
    if (val.type === 'paren!') {
      expect(val.values).toHaveLength(3);
    }
  });

  test('nested block stays inert', () => {
    const ast = parseString('[[1 2] [3 4]]');
    const val = astToValue(ast.children[0]);
    expect(val.type).toBe('block!');
    if (val.type === 'block!') {
      expect(val.values).toHaveLength(2);
      expect(val.values[0].type).toBe('block!');
      expect(val.values[1].type).toBe('block!');
    }
  });
});

describe('isTruthy', () => {
  test('none is falsy', () => {
    expect(isTruthy(NONE)).toBe(false);
  });

  test('false is falsy', () => {
    expect(isTruthy({ type: 'logic!', value: false })).toBe(false);
  });

  test('true is truthy', () => {
    expect(isTruthy({ type: 'logic!', value: true })).toBe(true);
  });

  test('0 is truthy', () => {
    expect(isTruthy({ type: 'integer!', value: 0 })).toBe(true);
  });

  test('empty string is truthy', () => {
    expect(isTruthy({ type: 'string!', value: '' })).toBe(true);
  });

  test('empty block is truthy', () => {
    expect(isTruthy({ type: 'block!', values: [] })).toBe(true);
  });
});

describe('typeOf', () => {
  test('returns type tag', () => {
    expect(typeOf({ type: 'integer!', value: 42 })).toBe('integer!');
    expect(typeOf({ type: 'string!', value: 'hi' })).toBe('string!');
    expect(typeOf(NONE)).toBe('none!');
  });
});

describe('valueToString', () => {
  test('integer', () => expect(valueToString({ type: 'integer!', value: 42 })).toBe('42'));
  test('string', () => expect(valueToString({ type: 'string!', value: 'hi' })).toBe('hi'));
  test('logic', () => expect(valueToString({ type: 'logic!', value: true })).toBe('true'));
  test('none', () => expect(valueToString(NONE)).toBe('none'));
  test('block', () => expect(valueToString({ type: 'block!', values: [{ type: 'integer!', value: 1 }] })).toBe('[1]'));
});
