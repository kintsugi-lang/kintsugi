import { describe, test, expect } from 'bun:test';
import { ParseError } from '@/parser';
import { AstContainer } from '@types';
import { parseString } from '@/helpers';

describe('atoms', () => {
  test('single integer', () => {
    const result = parseString('42');
    expect(result.type).toBe('Block');
    expect(result.children).toHaveLength(1);
    expect(result.children[0]).toEqual({ type: 'Integer', value: '42' });
  });

  test('multiple atoms', () => {
    const result = parseString('hello 42 "world"');
    expect(result.children).toHaveLength(3);
    expect(result.children[0]).toEqual({ type: 'Word', value: 'hello' });
    expect(result.children[1]).toEqual({ type: 'Integer', value: '42' });
    expect(result.children[2]).toEqual({ type: 'String', value: 'world' });
  });
});

describe('blocks', () => {
  test('empty block', () => {
    const result = parseString('[]');
    expect(result.children).toHaveLength(1);
    const block = result.children[0] as AstContainer;
    expect(block.type).toBe('Block');
    expect(block.children).toHaveLength(0);
  });

  test('block with atoms', () => {
    const result = parseString('[1 2 3]');
    const block = result.children[0] as AstContainer;
    expect(block.type).toBe('Block');
    expect(block.children).toHaveLength(3);
  });

  test('nested blocks', () => {
    const result = parseString('[1 [2 3]]');
    const outer = result.children[0] as AstContainer;
    expect(outer.children).toHaveLength(2);
    expect(outer.children[0]).toEqual({ type: 'Integer', value: '1' });
    const inner = outer.children[1] as AstContainer;
    expect(inner.type).toBe('Block');
    expect(inner.children).toEqual([
      { type: 'Integer', value: '2' },
      { type: 'Integer', value: '3' },
    ]);
  });
});

describe('parens', () => {
  test('paren group', () => {
    const result = parseString('(1 + 2)');
    const paren = result.children[0] as AstContainer;
    expect(paren.type).toBe('Paren');
    expect(paren.children).toHaveLength(3);
    expect(paren.children[0]).toEqual({ type: 'Integer', value: '1' });
    expect(paren.children[1]).toEqual({ type: 'Operator', value: '+' });
    expect(paren.children[2]).toEqual({ type: 'Integer', value: '2' });
  });
});

describe('mixed nesting', () => {
  test('blocks in parens', () => {
    const result = parseString('([1 2])');
    const paren = result.children[0] as AstContainer;
    expect(paren.type).toBe('Paren');
    const block = paren.children[0] as AstContainer;
    expect(block.type).toBe('Block');
    expect(block.children).toHaveLength(2);
  });

  test('parens in blocks', () => {
    const result = parseString('[(1 + 2)]');
    const block = result.children[0] as AstContainer;
    expect(block.type).toBe('Block');
    const paren = block.children[0] as AstContainer;
    expect(paren.type).toBe('Paren');
    expect(paren.children).toHaveLength(3);
  });
});

describe('word variants', () => {
  test('set-word', () => {
    const result = parseString('name:');
    expect(result.children[0]).toEqual({ type: 'SetWord', value: 'name' });
  });

  test('get-word', () => {
    const result = parseString(':name');
    expect(result.children[0]).toEqual({ type: 'GetWord', value: 'name' });
  });

  test('lit-word', () => {
    const result = parseString("'name");
    expect(result.children[0]).toEqual({ type: 'LitWord', value: 'name' });
  });

  test('paths pass through', () => {
    const result = parseString('obj/field');
    expect(result.children[0]).toEqual({ type: 'Path', value: 'obj/field' });
  });
});

describe('errors', () => {
  test('unclosed block', () => {
    expect(() => parseString('[1 2')).toThrow(ParseError);
    expect(() => parseString('[1 2')).toThrow('Unclosed [');
  });

  test('unclosed paren', () => {
    expect(() => parseString('(1 2')).toThrow(ParseError);
    expect(() => parseString('(1 2')).toThrow('Unclosed (');
  });

  test('unexpected ]', () => {
    expect(() => parseString(']')).toThrow(ParseError);
    expect(() => parseString(']')).toThrow('Unexpected ]');
  });

  test('unexpected )', () => {
    expect(() => parseString(')')).toThrow(ParseError);
    expect(() => parseString(')')).toThrow('Unexpected )');
  });

  test('mismatched [ closed by )', () => {
    expect(() => parseString('[1 2)')).toThrow(ParseError);
    expect(() => parseString('[1 2)')).toThrow('Mismatched');
  });

  test('mismatched ( closed by ]', () => {
    expect(() => parseString('(1 2]')).toThrow(ParseError);
    expect(() => parseString('(1 2]')).toThrow('Mismatched');
  });
});

describe('integration', () => {
  test('parses script-spec.ktg without errors', async () => {
    const file = Bun.file('./examples/script-spec.ktg');
    const source = await file.text();
    const result = parseString(source);
    expect(result.type).toBe('Block');
    expect(result.children.length).toBeGreaterThan(0);
  });
});
