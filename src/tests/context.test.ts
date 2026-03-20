import { describe, test, expect } from 'bun:test';
import { KtgContext } from '@/evaluator/context';

describe('KtgContext', () => {
  test('set and get', () => {
    const ctx = new KtgContext();
    ctx.set('x', { type: 'integer!', value: 42 });
    expect(ctx.get('x')).toEqual({ type: 'integer!', value: 42 });
  });

  test('get returns undefined for unset', () => {
    const ctx = new KtgContext();
    expect(ctx.get('x')).toBeUndefined();
  });

  test('has checks this context only', () => {
    const parent = new KtgContext();
    parent.set('x', { type: 'integer!', value: 1 });
    const child = parent.child();
    expect(child.has('x')).toBe(false);
    expect(child.get('x')).toEqual({ type: 'integer!', value: 1 });
  });

  test('parent chain lookup', () => {
    const grandparent = new KtgContext();
    grandparent.set('a', { type: 'integer!', value: 1 });
    const parent = grandparent.child();
    parent.set('b', { type: 'integer!', value: 2 });
    const child = parent.child();
    child.set('c', { type: 'integer!', value: 3 });

    expect(child.get('a')).toEqual({ type: 'integer!', value: 1 });
    expect(child.get('b')).toEqual({ type: 'integer!', value: 2 });
    expect(child.get('c')).toEqual({ type: 'integer!', value: 3 });
  });

  test('shadowing', () => {
    const parent = new KtgContext();
    parent.set('x', { type: 'integer!', value: 1 });
    const child = parent.child();
    child.set('x', { type: 'integer!', value: 2 });

    expect(child.get('x')).toEqual({ type: 'integer!', value: 2 });
    expect(parent.get('x')).toEqual({ type: 'integer!', value: 1 });
  });

  test('set always writes to this context', () => {
    const parent = new KtgContext();
    parent.set('x', { type: 'integer!', value: 1 });
    const child = parent.child();
    child.set('x', { type: 'integer!', value: 99 });

    expect(parent.get('x')).toEqual({ type: 'integer!', value: 1 });
    expect(child.get('x')).toEqual({ type: 'integer!', value: 99 });
  });
});
