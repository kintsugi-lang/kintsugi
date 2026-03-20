import { AstAtom, AstContainer, AstNode, TOKEN_TYPES } from '@types';
import type { KtgContext } from './context';

// --- Signals (thrown, not returned) ---

export class BreakSignal {
  constructor(public value: KtgValue = NONE) {}
}

export class ReturnSignal {
  constructor(public value: KtgValue) {}
}

export class KtgError extends Error {
  public data: KtgValue;
  constructor(
    public errorName: string,
    message: string,
    data?: KtgValue,
  ) {
    super(message);
    this.name = 'KtgError';
    this.data = data ?? NONE;
  }
}

// --- Runtime Value Types ---

export type KtgInteger  = { type: 'integer!'; value: number };
export type KtgFloat    = { type: 'float!';   value: number };
export type KtgString   = { type: 'string!';  value: string };
export type KtgLogic    = { type: 'logic!';   value: boolean };
export type KtgNone     = { type: 'none!' };
export type KtgChar     = { type: 'char!';    value: string };
export type KtgPair     = { type: 'pair!';    x: number; y: number };
export type KtgTuple    = { type: 'tuple!';   parts: number[] };
export type KtgDate     = { type: 'date!';    value: string };
export type KtgTime     = { type: 'time!';    value: string };
export type KtgBinary   = { type: 'binary!';  value: Uint8Array };
export type KtgFile     = { type: 'file!';    value: string };
export type KtgUrl      = { type: 'url!';     value: string };
export type KtgEmail    = { type: 'email!';   value: string };

export type KtgWord     = { type: 'word!';     name: string; bound?: KtgContext };
export type KtgSetWord  = { type: 'set-word!'; name: string; bound?: KtgContext };
export type KtgGetWord  = { type: 'get-word!'; name: string; bound?: KtgContext };
export type KtgLitWord  = { type: 'lit-word!'; name: string };
export type KtgPath     = { type: 'path!';     segments: string[] };
export type KtgSetPath  = { type: 'set-path!'; segments: string[] };
export type KtgGetPath  = { type: 'get-path!'; segments: string[] };
export type KtgLitPath  = { type: 'lit-path!'; segments: string[] };

export type KtgBlock    = { type: 'block!';    values: KtgValue[] };
export type KtgParen    = { type: 'paren!';    values: KtgValue[] };
export type KtgMap      = { type: 'map!';      entries: Map<string, KtgValue> };
export type KtgCtxValue = { type: 'context!';   context: KtgContext };

export type ParamSpec = { name: string; typeConstraint?: string; elementType?: string };

export type FuncSpec = {
  params: ParamSpec[];
  refinements: { name: string; params: ParamSpec[] }[];
  returnType?: string;
};

export type NativeFn = (args: KtgValue[], evaluator: any, callerCtx: any, refinements: string[]) => KtgValue;

export type KtgFunction = { type: 'function!'; spec: FuncSpec; body: KtgBlock; closure: KtgContext };
export type KtgNative   = { type: 'native!';   name: string; arity: number; refinementArgs?: Record<string, number>; fn: NativeFn };
export type KtgOp       = { type: 'op!';       name: string; fn: (l: KtgValue, r: KtgValue) => KtgValue };

export type KtgTypeName = { type: 'type!';     name: string };
export type KtgTypeset  = { type: 'typeset!';  name: string; types: string[]; guard?: KtgBlock };
export type KtgOperator = { type: 'operator!'; symbol: string };

export type KtgValue =
  | KtgInteger | KtgFloat | KtgString | KtgLogic | KtgNone
  | KtgChar | KtgPair | KtgTuple | KtgDate | KtgTime
  | KtgBinary | KtgFile | KtgUrl | KtgEmail
  | KtgWord | KtgSetWord | KtgGetWord | KtgLitWord
  | KtgPath | KtgSetPath | KtgGetPath | KtgLitPath
  | KtgBlock | KtgParen | KtgMap | KtgCtxValue
  | KtgFunction | KtgNative | KtgOp
  | KtgTypeName | KtgTypeset | KtgOperator;

// --- Constants ---

export const NONE: KtgNone = { type: 'none!' };
export const TRUE: KtgLogic = { type: 'logic!', value: true };
export const FALSE: KtgLogic = { type: 'logic!', value: false };

// --- Conversion ---

const LOGIC_TRUE = new Set(['true']);

function hexToUint8Array(hex: string): Uint8Array {
  const clean = hex.replace(/\s/g, '');
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < clean.length; i += 2) {
    bytes[i / 2] = parseInt(clean.substring(i, i + 2), 16);
  }
  return bytes;
}

export function astToValue(node: AstNode): KtgValue {
  if ('children' in node) {
    const values = node.children.map(astToValue);
    if (node.type === TOKEN_TYPES.BLOCK) return { type: 'block!', values };
    if (node.type === TOKEN_TYPES.PAREN) return { type: 'paren!', values };
    throw new KtgError('internal', `Unknown container type: ${node.type}`);
  }

  const atom = node as AstAtom;
  const v = atom.value;

  switch (atom.type) {
    case TOKEN_TYPES.INTEGER:  return { type: 'integer!', value: parseInt(v, 10) };
    case TOKEN_TYPES.FLOAT:    return { type: 'float!',   value: parseFloat(v) };
    case TOKEN_TYPES.STRING:   return { type: 'string!',  value: v };
    case TOKEN_TYPES.LOGIC:    return { type: 'logic!',   value: LOGIC_TRUE.has(v) };
    case TOKEN_TYPES.NONE:     return NONE;
    case TOKEN_TYPES.CHAR:     return { type: 'char!',    value: v };
    case TOKEN_TYPES.PAIR: {
      const [x, y] = v.split('x').map(Number);
      return { type: 'pair!', x, y };
    }
    case TOKEN_TYPES.TUPLE:    return { type: 'tuple!', parts: v.split('.').map(Number) };
    case TOKEN_TYPES.MONEY:    return { type: 'float!', value: parseFloat(v) };
    case TOKEN_TYPES.DATE:     return { type: 'date!',  value: v };
    case TOKEN_TYPES.TIME:     return { type: 'time!',  value: v };
    case TOKEN_TYPES.BINARY:   return { type: 'binary!', value: hexToUint8Array(v) };
    case TOKEN_TYPES.FILE:     return { type: 'file!',   value: v };
    case TOKEN_TYPES.URL:      return { type: 'url!',    value: v };
    case TOKEN_TYPES.EMAIL:    return { type: 'email!',  value: v };
    case TOKEN_TYPES.WORD:     return { type: 'word!',   name: v };
    case TOKEN_TYPES.SET_WORD: return { type: 'set-word!', name: v };
    case TOKEN_TYPES.GET_WORD: return { type: 'get-word!', name: v };
    case TOKEN_TYPES.LIT_WORD: return { type: 'lit-word!', name: v };
    case TOKEN_TYPES.PATH:     return { type: 'path!',     segments: v.split('/') };
    case TOKEN_TYPES.SET_PATH: return { type: 'set-path!', segments: v.split('/') };
    case TOKEN_TYPES.GET_PATH: return { type: 'get-path!', segments: v.split('/') };
    case TOKEN_TYPES.LIT_PATH: return { type: 'lit-path!', segments: v.split('/') };
    case TOKEN_TYPES.OPERATOR: return { type: 'operator!', symbol: v };
    case TOKEN_TYPES.FUNCTION: return { type: 'word!', name: 'function' };
    case TOKEN_TYPES.DIRECTIVE: return { type: 'word!', name: `#${v}` };
    case TOKEN_TYPES.LIFECYCLE: return { type: 'word!', name: `@${v}` };
    case TOKEN_TYPES.COMMENT:  return NONE; // comments are discarded
    case TOKEN_TYPES.STUB:     return NONE;
    default:
      throw new KtgError('internal', `Unknown atom type: ${atom.type}`);
  }
}

// --- Predicates ---

export function isTruthy(val: KtgValue): boolean {
  if (val.type === 'none!') return false;
  if (val.type === 'logic!' && val.value === false) return false;
  return true;
}

export function typeOf(val: KtgValue): string {
  return val.type;
}

// --- Display ---

export function valueToString(val: KtgValue): string {
  switch (val.type) {
    case 'integer!':   return String(val.value);
    case 'float!':     return String(val.value);
    case 'string!':    return val.value;
    case 'logic!':     return val.value ? 'true' : 'false';
    case 'none!':      return 'none';
    case 'char!':      return val.value;
    case 'pair!':      return `${val.x}x${val.y}`;
    case 'tuple!':     return val.parts.join('.');
    case 'date!':      return val.value;
    case 'time!':      return val.value;
    case 'binary!':    return `#{${Array.from(val.value).map(b => b.toString(16).padStart(2, '0').toUpperCase()).join('')}}`;
    case 'file!':      return `%${val.value}`;
    case 'url!':       return val.value;
    case 'email!':     return val.value;
    case 'word!':      return val.name;
    case 'set-word!':  return `${val.name}:`;
    case 'get-word!':  return `:${val.name}`;
    case 'lit-word!':  return `'${val.name}`;
    case 'path!':      return val.segments.join('/');
    case 'set-path!':  return `${val.segments.join('/')}:`;
    case 'get-path!':  return `:${val.segments.join('/')}`;
    case 'lit-path!':  return `'${val.segments.join('/')}`;
    case 'block!':     return `[${val.values.map(valueToString).join(' ')}]`;
    case 'paren!':     return `(${val.values.map(valueToString).join(' ')})`;
    case 'map!': {
      const pairs: string[] = [];
      val.entries.forEach((v, k) => pairs.push(`${k} ${valueToString(v)}`));
      return `#(${pairs.join(' ')})`;
    }
    case 'context!':    return 'context!';
    case 'function!':  return 'function!';
    case 'native!':    return `native!:${val.name}`;
    case 'op!':        return `op!:${val.name}`;
    case 'type!':      return val.name;
    case 'typeset!':   return val.name;
    case 'operator!':  return val.symbol;
  }
}

export function isCallable(val: KtgValue): val is KtgFunction | KtgNative {
  return val.type === 'function!' || val.type === 'native!';
}

export function isNumeric(val: KtgValue): val is KtgInteger | KtgFloat {
  return val.type === 'integer!' || val.type === 'float!';
}

export function numVal(val: KtgValue): number {
  if (val.type === 'integer!' || val.type === 'float!') return val.value;
  throw new KtgError('type', `Expected number, got ${val.type}`);
}
