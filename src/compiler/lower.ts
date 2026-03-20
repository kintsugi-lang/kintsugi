import {
  IRModule, IRDecl, IRStmt, IRExpr, IRParam, IRType,
  IRFuncDecl, IRVarDecl, IRExprStmt, IRIf, IRForRange, IRForEach,
  IRLoop, IRBreak, IRReturn, IRSet, IRThrow, IRTry, IRFieldSet,
  IRLiteral, IRGet, IRCall, IRBuiltinCall, IRBinOp, IRUnaryOp,
  IRBlockLiteral, IRFieldGet, IRMakeContext, IRMakeClosure, IRInlineIf, IRNone,
} from './ir';
import { parseString } from '@/helpers';
import { astToValue, valueToString } from '@/evaluator/values';
import type { KtgValue, KtgBlock, FuncSpec } from '@/evaluator/values';
import { lowerError as compileError } from './errors';

// ============================================================
// Built-in arity table
// ============================================================

const BUILTINS: Record<string, number> = {
  'print': 1, 'probe': 1,
  'if': 2, 'either': 3, 'unless': 2,
  'loop': 1, 'break': 0, 'return': 1, 'not': 1,
  'length?': 1, 'empty?': 1, 'first': 1, 'second': 1, 'last': 1,
  'pick': 2, 'copy': 1, 'append': 2, 'insert': 3, 'remove': 2,
  'select': 2, 'has?': 2, 'index?': 2,
  'type?': 1, 'to': 2, 'make': 2,
  'join': 2, 'rejoin': 1, 'trim': 1, 'split': 2,
  'uppercase': 1, 'lowercase': 1, 'replace': 3,
  'min': 2, 'max': 2, 'abs': 1, 'negate': 1, 'round': 1,
  'odd?': 1, 'even?': 1,
  'context': 1,
  'error': 3, 'try': 1,
  'match': 2, 'parse': 2, 'is?': 2,
  'function': 2, 'attempt': 1, 'require': 1,
  // Type predicates
  'none?': 1, 'integer?': 1, 'float?': 1, 'string?': 1, 'logic?': 1,
  'block?': 1, 'context?': 1, 'function?': 1,
  'pair?': 1, 'tuple?': 1, 'date?': 1, 'time?': 1,
  'file?': 1, 'url?': 1, 'email?': 1, 'word?': 1, 'meta-word?': 1, 'map?': 1,
};

const INFIX_OPS = new Set(['+', '-', '*', '/', '%', '=', '<>', '<', '>', '<=', '>=']);
const INFIX_WORDS = new Set(['and', 'or']);

// ============================================================
// Scope — track what's defined and its arity/type
// ============================================================

interface ScopeEntry {
  type: IRType;
  arity?: number;    // if it's a callable
  params?: IRParam[];
  returnType?: IRType;
}

class Scope {
  private entries: Map<string, ScopeEntry> = new Map();
  private parent: Scope | null;

  constructor(parent: Scope | null = null) {
    this.parent = parent;
  }

  set(name: string, entry: ScopeEntry): void {
    this.entries.set(name, entry);
  }

  get(name: string): ScopeEntry | undefined {
    return this.entries.get(name) ?? this.parent?.get(name);
  }

  child(): Scope {
    return new Scope(this);
  }
}

// ============================================================
// Public API
// ============================================================

export function lower(source: string): IRModule {
  const ast = parseString(source);
  const block = astToValue(ast) as KtgBlock;

  const scope = new Scope();
  // Register builtins in scope
  for (const [name, arity] of Object.entries(BUILTINS)) {
    scope.set(name, { type: 'native!', arity });
  }

  // Strip header: if first two values are word 'Kintsugi' (or path 'Kintsugi/Lua' etc) + block, skip them
  let bodyValues = block.values;
  if (bodyValues.length >= 2) {
    const first = bodyValues[0];
    const isHeader = (first.type === 'word!' && first.name === 'Kintsugi')
      || (first.type === 'path!' && first.segments[0] === 'Kintsugi');
    if (isHeader && bodyValues[1].type === 'block!') {
      bodyValues = bodyValues.slice(2);
    }
  }

  const declarations = lowerBlock(bodyValues, scope);

  return {
    name: '',
    dialect: 'script',
    exports: [],
    imports: [],
    declarations,
  };
}

// ============================================================
// Block lowering — sequence of expressions/statements
// ============================================================

function lowerBlock(values: KtgValue[], scope: Scope): IRDecl[] {
  const decls: IRDecl[] = [];
  let pos = 0;

  while (pos < values.length) {
    const [decl, nextPos] = lowerNext(values, pos, scope);
    if (decl) decls.push(decl);
    pos = nextPos;
  }

  return decls;
}

// Lower the next expression/statement from the values array.
// Returns [IRDecl | null, newPos]
function lowerNext(values: KtgValue[], pos: number, scope: Scope): [IRDecl | null, number] {
  const val = values[pos];

  // Set-word: variable or function declaration
  if (val.type === 'set-word!') {
    const name = val.name;

    // Check if next is 'function' keyword — pre-register for recursion
    if (pos + 1 < values.length && values[pos + 1].type === 'word!' && (values[pos + 1] as any).name === 'function') {
      const [expr, nextPos] = lowerFunctionExpr(values, pos + 1, scope, name);
      const funcDecl: IRFuncDecl = {
        tag: 'func',
        name,
        params: (expr as any).params,
        returnType: (expr as any).returnType,
        body: (expr as any).body,
        refinements: (expr as any).refinements,
      };
      return [funcDecl, nextPos];
    }

    const [expr, nextPos] = lowerExpr(values, pos + 1, scope);

    const varDecl: IRVarDecl = { tag: 'var', name, type: expr.type ?? 'any!', value: expr };

    // Track callable variables
    if (expr.tag === 'make-closure') {
      scope.set(name, { type: 'function!', arity: expr.params.length, returnType: expr.returnType });
    } else if (expr.type === 'function!' && expr.tag === 'call') {
      // Result of a function that returns a function — we don't know arity
      // Look up the called function's return info
      const calledName = typeof expr.func === 'string' ? expr.func : null;
      const calledEntry = calledName ? scope.get(calledName) : null;
      // Check if the called function's body returns a closure we can inspect
      scope.set(name, { type: 'function!', arity: 1 }); // Default arity 1
    } else {
      scope.set(name, { type: expr.type ?? 'any!' });
    }

    return [varDecl, nextPos];
  }

  // Word: could be a function call, control flow, or variable reference
  if (val.type === 'word!') {
    const name = val.name;

    // Control flow — statement context
    if (name === 'if') return lowerIf(values, pos, scope);
    if (name === 'either') return lowerEither(values, pos, scope);
    if (name === 'unless') return lowerUnless(values, pos, scope);
    if (name === 'loop') return lowerLoop(values, pos, scope);
    if (name === 'break') return [{ tag: 'break' }, pos + 1];
    if (name === 'return') {
      const [expr, nextPos] = lowerExpr(values, pos + 1, scope);
      return [{ tag: 'return', value: expr }, nextPos];
    }
    if (name === 'match') return lowerMatch(values, pos, scope);
    if (name === 'error') return lowerError(values, pos, scope);
    if (name === 'try') return lowerTry(values, pos, scope);
    if (name === 'attempt') return lowerAttempt(values, pos, scope);
    if (name === 'do') { compileError('do', 'do requires the interpreter — use #preprocess for compile-time evaluation'); }
    if (name === 'bind') {
      // No-op in compiled code — skip bind + its two args
      pos++;
      const [, afterBlock] = lowerExpr(values, pos, scope);
      const [, afterCtx] = lowerExpr(values, afterBlock, scope);
      return [null, afterCtx];
    }

    // Function/builtin call — lower as expression statement
    const [expr, nextPos] = lowerExpr(values, pos, scope);
    return [{ tag: 'expr', expr } as IRExprStmt, nextPos];
  }

  // Path: could be loop/collect, loop/fold, loop/partition, try/handle, or field access
  if (val.type === 'path!') {
    const segments = val.segments;

    // try/handle [body] :handler
    if (segments[0] === 'try' && segments.length === 2 && segments[1] === 'handle') {
      return lowerTryHandle(values, pos, scope);
    }

    if (segments[0] === 'loop' && segments.length === 2) {
      const refinement = segments[1];
      // pos points to the path token; the block is at pos+1
      const block = values[pos + 1] as KtgBlock;
      const blockValues = block.values;
      const first = blockValues[0];

      if (first && first.type === 'word!' && (first.name === 'for' || first.name === 'from')) {
        const decls = lowerLoopDialect(blockValues, scope, refinement);
        // Return all decls — for multi-decl refinements we flatten
        if (decls.length === 1) return [decls[0], pos + 2];
        // For multiple decls, return first and note we need to splice
        // For now, wrap in a block-like structure
        return [decls[0], pos + 2]; // Simplified
      }
    }

    // Regular path expression
    const [expr, nextPos] = lowerExpr(values, pos, scope);
    return [{ tag: 'expr', expr } as IRExprStmt, nextPos];
  }

  // Set-path: obj/field: value
  if (val.type === 'set-path!') {
    const segments = val.segments;
    let target: IRExpr = { tag: 'get', type: 'any!', name: segments[0] };
    for (let i = 1; i < segments.length - 1; i++) {
      target = { tag: 'field-get', type: 'any!', target, field: segments[i] };
    }
    const [value, nextPos] = lowerExpr(values, pos + 1, scope);
    return [{
      tag: 'field-set',
      target,
      field: segments[segments.length - 1],
      value,
    } as IRFieldSet, nextPos];
  }

  // Path: field access or refinement call
  if (val.type === 'path!') {
    const [expr, nextPos] = lowerExpr(values, pos, scope);
    return [{ tag: 'expr', expr } as IRExprStmt, nextPos];
  }

  // Anything else: lower as expression
  const [expr, nextPos] = lowerExpr(values, pos, scope);
  return [{ tag: 'expr', expr } as IRExprStmt, nextPos];
}

// ============================================================
// Expression lowering
// ============================================================

type ExprResult = IRExpr | { tag: 'func-raw'; params: IRParam[]; returnType: IRType; body: IRStmt[]; refinements?: any[] };

function lowerExpr(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  let [expr, nextPos] = lowerAtom(values, pos, scope);

  // Infix continuation — left to right, no precedence
  while (nextPos < values.length) {
    const next = values[nextPos];
    if (next.type === 'operator!' && INFIX_OPS.has(next.symbol)) {
      const op = next.symbol as IRBinOp['op'];
      const [right, afterRight] = lowerAtom(values, nextPos + 1, scope);
      const resultType = inferBinopType(op, expr.type, right.type);
      expr = { tag: 'binop', type: resultType, op, left: expr, right };
      nextPos = afterRight;
    } else if (next.type === 'word!' && INFIX_WORDS.has(next.name)) {
      const op = next.name as 'and' | 'or';
      const [right, afterRight] = lowerAtom(values, nextPos + 1, scope);
      expr = { tag: 'binop', type: 'any!', op, left: expr, right };
      nextPos = afterRight;
    } else {
      break;
    }
  }

  return [expr, nextPos];
}

function lowerAtom(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  if (pos >= values.length) {
    return [{ tag: 'none', type: 'none!' }, pos];
  }

  const val = values[pos];

  switch (val.type) {
    case 'integer!':
      return [{ tag: 'literal', type: 'integer!', value: val.value }, pos + 1];
    case 'float!':
      return [{ tag: 'literal', type: 'float!', value: val.value }, pos + 1];
    case 'string!':
      return [{ tag: 'literal', type: 'string!', value: val.value }, pos + 1];
    case 'logic!':
      return [{ tag: 'literal', type: 'logic!', value: val.value }, pos + 1];
    case 'none!':
      return [{ tag: 'none', type: 'none!' }, pos + 1];
    case 'lit-word!':
      return [{ tag: 'literal', type: 'lit-word!', value: val.name }, pos + 1];

    case 'block!':
      return [lowerBlockLiteral(val as KtgBlock, scope), pos + 1];

    case 'paren!': {
      // Paren evaluates its contents
      const innerDecls = lowerBlock((val as any).values, scope);
      // Last expression is the result
      const lastDecl = innerDecls[innerDecls.length - 1];
      if (lastDecl && lastDecl.tag === 'expr') {
        return [(lastDecl as IRExprStmt).expr, pos + 1];
      }
      if (lastDecl && lastDecl.tag === 'var') {
        return [(lastDecl as IRVarDecl).value, pos + 1];
      }
      return [{ tag: 'none', type: 'none!' }, pos + 1];
    }

    case 'word!': {
      const name = val.name;

      // Control flow in expression position → inline-if
      if (name === 'if') {
        return lowerIfExpr(values, pos, scope);
      }
      if (name === 'either') {
        return lowerEitherExpr(values, pos, scope);
      }
      if (name === 'unless') {
        return lowerUnlessExpr(values, pos, scope);
      }

      // function keyword — returns a raw function descriptor
      if (name === 'function') {
        return lowerFunctionExpr(values, pos, scope) as any;
      }

      // context [fields] — lower to IRMakeContext
      if (name === 'context') {
        return lowerContextExpr(values, pos, scope);
      }

      // Tier 3 homoiconic words — special lowering
      if (name === 'compose') return lowerCompose(values, pos, scope);
      if (name === 'reduce') return lowerReduce(values, pos, scope);
      if (name === 'do') return compileError('do', 'do requires the interpreter — use #preprocess for compile-time evaluation'), [{ tag: 'none', type: 'none!' }, pos + 1];
      if (name === 'bind') return lowerBind(values, pos, scope);
      if (name === 'words-of') return lowerWordsOf(values, pos, scope);

      // Control flow words — special lowering
      if (name === 'all') return lowerAll(values, pos, scope);
      if (name === 'any') return lowerAny(values, pos, scope);
      if (name === 'apply') return lowerApply(values, pos, scope);
      if (name === 'set') return lowerSet(values, pos, scope);

      // Check if it's a known callable
      const entry = scope.get(name);
      if (entry && entry.arity !== undefined) {
        return lowerCallable(name, entry, values, pos + 1, scope);
      }

      // Variable reference
      return [{ tag: 'get', type: entry?.type ?? 'any!', name }, pos + 1];
    }

    case 'get-word!':
      return [{ tag: 'get', type: 'any!', name: val.name }, pos + 1];

    case 'path!': {
      const segments = val.segments;
      const headName = segments[0];
      const entry = scope.get(headName);

      // Known callable with refinements: func/refine args
      if (entry && entry.arity !== undefined && segments.length === 2) {
        const refinements = segments.slice(1);
        return lowerRefinementCall(headName, entry, refinements, values, pos + 1, scope);
      }

      // Build field access chain
      let expr: IRExpr = { tag: 'get', type: entry?.type ?? 'any!', name: headName };
      for (let i = 1; i < segments.length; i++) {
        expr = { tag: 'field-get', type: 'any!', target: expr, field: segments[i] };
      }

      // Deep path call: if the next value looks like an argument (not an operator
      // or set-word), treat this path as a callable and consume args eagerly.
      // This handles love/graphics/circle "fill" x y 20
      if (pos + 1 < values.length) {
        const next = values[pos + 1];
        const isArg = next && next.type !== 'set-word!' && next.type !== 'set-path!'
          && !(next.type === 'operator!' && INFIX_OPS.has((next as any).symbol))
          && !(next.type === 'word!' && INFIX_WORDS.has((next as any).name));

        if (isArg && next.type !== 'block!') {
          // Consume scalar args until we hit a block, set-word, keyword, or another path
          const args: IRExpr[] = [];
          let argPos = pos + 1;
          while (argPos < values.length) {
            const peek = values[argPos];
            // Stop at blocks (they're bodies for control flow), set-words, set-paths,
            // keywords, paths, or get-words
            if (peek.type === 'block!' || peek.type === 'set-word!' || peek.type === 'set-path!') break;
            if (peek.type === 'path!' || peek.type === 'get-word!') break;
            if (peek.type === 'word!' && (BUILTINS[peek.name] !== undefined || peek.name === 'if'
              || peek.name === 'either' || peek.name === 'unless' || peek.name === 'loop'
              || peek.name === 'return' || peek.name === 'break' || peek.name === 'error'
              || peek.name === 'match' || peek.name === 'try')) break;

            const [arg, nextArgPos] = lowerExpr(values, argPos, scope);
            args.push(arg);
            argPos = nextArgPos;
          }
          if (args.length > 0) {
            return [{ tag: 'call', type: 'any!', func: expr, args } as IRCall, argPos];
          }
        }
      }

      // No args consumed. If the root is unknown (extern), wrap in __call_or_get
      // for the zero-arg ambiguity. If root is known in scope, it's a value access.
      if (!entry && segments.length > 1) {
        return [{ tag: 'builtin', type: 'any!', name: '__call_or_get', args: [expr] } as IRBuiltinCall, pos + 1];
      }

      return [expr, pos + 1];
    }

    case 'get-path!': {
      // Get-path: always value access, never call
      const segments = val.segments;
      let expr: IRExpr = { tag: 'get', type: 'any!', name: segments[0] };
      for (let i = 1; i < segments.length; i++) {
        expr = { tag: 'field-get', type: 'any!', target: expr, field: segments[i] };
      }
      return [expr, pos + 1];
    }

    case 'set-path!': {
      return [{ tag: 'none', type: 'none!' }, pos + 1];
    }

    default:
      return [{ tag: 'none', type: 'none!' }, pos + 1];
  }
}

// ============================================================
// Callable lowering — consume args based on arity
// ============================================================

function lowerCallable(
  name: string,
  entry: ScopeEntry,
  values: KtgValue[],
  pos: number,
  scope: Scope,
): [IRExpr, number] {
  const arity = entry.arity!;
  const args: IRExpr[] = [];

  for (let i = 0; i < arity; i++) {
    if (pos >= values.length) break;
    const [arg, nextPos] = lowerExpr(values, pos, scope);
    args.push(arg);
    pos = nextPos;
  }

  const isBuiltin = BUILTINS[name] !== undefined;
  const returnType = entry.returnType ?? 'any!';

  if (isBuiltin) {
    return [{ tag: 'builtin', type: returnType, name, args }, pos];
  }

  return [{ tag: 'call', type: returnType, func: name, args }, pos];
}

function lowerRefinementCall(
  name: string,
  entry: ScopeEntry,
  refinements: string[],
  values: KtgValue[],
  pos: number,
  scope: Scope,
): [IRExpr, number] {
  const arity = entry.arity!;
  const args: IRExpr[] = [];

  for (let i = 0; i < arity; i++) {
    if (pos >= values.length) break;
    const [arg, nextPos] = lowerExpr(values, pos, scope);
    args.push(arg);
    pos = nextPos;
  }

  // TODO: consume extra args for refinement params

  const isBuiltin = BUILTINS[name] !== undefined;
  if (isBuiltin) {
    return [{ tag: 'builtin', type: 'any!', name, args, refinements }, pos];
  }
  return [{ tag: 'call', type: 'any!', func: name, args, refinements }, pos];
}

// ============================================================
// Function lowering
// ============================================================

function lowerContextExpr(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'context'
  const block = values[pos] as KtgBlock;
  pos++;

  // Walk the block: set-words followed by expressions become fields
  const fields: { name: string; type: IRType; value: IRExpr }[] = [];
  const fieldValues = block.values;
  let i = 0;

  while (i < fieldValues.length) {
    if (fieldValues[i].type === 'set-word!') {
      const fieldName = (fieldValues[i] as any).name;
      i++;
      const [value, nextI] = lowerExpr(fieldValues, i, scope);
      fields.push({ name: fieldName, type: value.type ?? 'any!', value });
      i = nextI;
    } else {
      i++;
    }
  }

  return [{ tag: 'make-context', type: 'context!', fields }, pos];
}

function lowerFunctionExpr(values: KtgValue[], pos: number, scope: Scope, name?: string): [ExprResult, number] {
  // function [spec] [body]
  pos++; // skip 'function' word
  if (pos >= values.length || values[pos].type !== 'block!') {
    compileError(name ? `function ${name}` : 'function', 'expected spec block');
  }
  const specBlock = values[pos] as KtgBlock;
  pos++;
  if (pos >= values.length || values[pos].type !== 'block!') {
    compileError(name ? `function ${name}` : 'function', 'expected body block');
  }
  const bodyBlock = values[pos] as KtgBlock;
  pos++;

  const { params, returnType, refinements } = parseSpecBlock(specBlock);

  // Pre-register the function in scope for recursive calls
  if (name) {
    scope.set(name, {
      type: 'function!',
      arity: params.length,
      params,
      returnType,
    });
  }

  const funcScope = scope.child();
  for (const p of params) {
    funcScope.set(p.name, { type: p.type });
  }

  const bodyStmts = lowerBlockToStmts(bodyBlock.values, funcScope);

  // Infer return type from last statement if not explicitly declared
  let inferredReturnType = returnType;
  if (inferredReturnType === 'any!' && bodyStmts.length > 0) {
    const lastStmt = bodyStmts[bodyStmts.length - 1];
    if (lastStmt.tag === 'expr' && (lastStmt as IRExprStmt).expr.tag === 'make-closure') {
      inferredReturnType = 'function!';
    }
  }

  // Update scope with inferred return type
  if (name && inferredReturnType !== returnType) {
    scope.set(name, {
      type: 'function!',
      arity: params.length,
      params,
      returnType: inferredReturnType,
    });
  }

  // If named, return func-raw for the set-word handler to convert to IRFuncDecl
  // If anonymous, return IRMakeClosure directly
  if (name) {
    return [{
      tag: 'func-raw' as any,
      params,
      returnType: inferredReturnType,
      body: bodyStmts,
      refinements,
    }, pos];
  }

  return [{
    tag: 'make-closure',
    type: 'function!',
    params,
    returnType,
    captures: [], // Lua/JS handle captures natively
    body: bodyStmts,
  } as IRMakeClosure, pos];
}

function parseSpecBlock(spec: KtgBlock): { params: IRParam[]; returnType: IRType; refinements: any[] } {
  const params: IRParam[] = [];
  const refinements: any[] = [];
  let returnType: IRType = 'any!';
  const values = spec.values;

  let i = 0;
  while (i < values.length) {
    const v = values[i];

    // return: [type!]
    if (v.type === 'set-word!' && v.name === 'return') {
      i++;
      if (i < values.length && values[i].type === 'block!') {
        const typeBlock = values[i] as KtgBlock;
        if (typeBlock.values.length > 0 && typeBlock.values[0].type === 'word!') {
          returnType = (typeBlock.values[0] as any).name as IRType;
        }
        i++;
      }
      continue;
    }

    // /refinement
    if (v.type === 'operator!' && (v as any).symbol === '/' && i + 1 < values.length && values[i + 1].type === 'word!') {
      i++;
      const refName = (values[i] as any).name;
      // TODO: parse refinement params
      refinements.push({ name: refName, params: [] });
      i++;
      continue;
    }

    // Skip strings (documentation)
    if (v.type === 'string!') { i++; continue; }
    // Skip type blocks (follow a param)
    if (v.type === 'block!') { i++; continue; }

    // Param word
    if (v.type === 'word!') {
      const name = v.name;
      let type: IRType = 'any!';
      if (i + 1 < values.length && values[i + 1].type === 'block!') {
        const typeBlock = values[i + 1] as KtgBlock;
        if (typeBlock.values.length > 0 && typeBlock.values[0].type === 'word!') {
          type = (typeBlock.values[0] as any).name as IRType;
        }
        i++; // skip type block
      }
      params.push({ name, type });
      i++;
      continue;
    }

    i++;
  }

  return { params, returnType, refinements };
}

// ============================================================
// Control flow lowering
// ============================================================

function lowerIfExpr(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'if'
  const [condition, afterCond] = lowerExpr(values, pos, scope);
  if (afterCond >= values.length || values[afterCond].type !== 'block!') {
    compileError('if', 'expected a block after condition');
  }
  const bodyBlock = values[afterCond] as KtgBlock;
  const body = lowerBlockToStmts(bodyBlock.values, scope);
  return [{ tag: 'inline-if', type: 'any!', condition, then: body } as IRInlineIf, afterCond + 1];
}

function lowerEitherExpr(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'either'
  const [condition, afterCond] = lowerExpr(values, pos, scope);
  if (afterCond >= values.length || values[afterCond].type !== 'block!') {
    compileError('either', 'expected a block after condition');
  }
  if (afterCond + 1 >= values.length || values[afterCond + 1].type !== 'block!') {
    compileError('either', 'expected two blocks');
  }
  const thenBlock = values[afterCond] as KtgBlock;
  const elseBlock = values[afterCond + 1] as KtgBlock;
  const thenBody = lowerBlockToStmts(thenBlock.values, scope);
  const elseBody = lowerBlockToStmts(elseBlock.values, scope);
  return [{ tag: 'inline-if', type: 'any!', condition, then: thenBody, else: elseBody } as IRInlineIf, afterCond + 2];
}

function lowerUnlessExpr(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'unless'
  const [condition, afterCond] = lowerExpr(values, pos, scope);
  if (afterCond >= values.length || values[afterCond].type !== 'block!') {
    compileError('unless', 'expected a block after condition');
  }
  const bodyBlock = values[afterCond] as KtgBlock;
  const body = lowerBlockToStmts(bodyBlock.values, scope);
  const negated: IRUnaryOp = { tag: 'unary', type: 'logic!', op: 'not', operand: condition };
  return [{ tag: 'inline-if', type: 'any!', condition: negated, then: body } as IRInlineIf, afterCond + 1];
}

function lowerIf(values: KtgValue[], pos: number, scope: Scope): [IRIf, number] {
  pos++; // skip 'if'
  const [condition, afterCond] = lowerExpr(values, pos, scope);
  if (afterCond >= values.length || values[afterCond].type !== 'block!') {
    compileError('if', 'expected a block after condition');
  }
  const bodyBlock = values[afterCond] as KtgBlock;
  const body = lowerBlockToStmts(bodyBlock.values, scope);
  return [{ tag: 'if', condition, then: body }, afterCond + 1];
}

function lowerEither(values: KtgValue[], pos: number, scope: Scope): [IRIf, number] {
  pos++; // skip 'either'
  const [condition, afterCond] = lowerExpr(values, pos, scope);
  if (afterCond >= values.length || values[afterCond].type !== 'block!') {
    compileError('either', 'expected a block after condition');
  }
  if (afterCond + 1 >= values.length || values[afterCond + 1].type !== 'block!') {
    compileError('either', 'expected two blocks (then and else)');
  }
  const thenBlock = values[afterCond] as KtgBlock;
  const elseBlock = values[afterCond + 1] as KtgBlock;
  const thenBody = lowerBlockToStmts(thenBlock.values, scope);
  const elseBody = lowerBlockToStmts(elseBlock.values, scope);
  return [{ tag: 'if', condition, then: thenBody, else: elseBody }, afterCond + 2];
}

function lowerUnless(values: KtgValue[], pos: number, scope: Scope): [IRIf, number] {
  pos++; // skip 'unless'
  const [condition, afterCond] = lowerExpr(values, pos, scope);
  const bodyBlock = values[afterCond] as KtgBlock;
  const body = lowerBlockToStmts(bodyBlock.values, scope);
  // unless = if (not condition)
  const negated: IRUnaryOp = { tag: 'unary', type: 'logic!', op: 'not', operand: condition };
  return [{ tag: 'if', condition: negated, then: body }, afterCond + 1];
}

function lowerLoop(values: KtgValue[], pos: number, scope: Scope, refinement?: string): [IRDecl | IRDecl[], number] {
  pos++; // skip 'loop'
  if (pos >= values.length || values[pos].type !== 'block!') {
    compileError('loop', 'expected a block');
  }
  const block = values[pos] as KtgBlock;
  pos++;

  const blockValues = block.values;
  if (blockValues.length === 0) {
    return [{ tag: 'loop', body: [] } as IRLoop, pos];
  }

  const first = blockValues[0];

  // Check for dialect: first word is 'for' or 'from'
  if (first.type === 'word!' && (first.name === 'for' || first.name === 'from')) {
    const decls = lowerLoopDialect(blockValues, scope, refinement);
    return [decls.length === 1 ? decls[0] : decls, pos];
  }

  // Simple infinite loop
  const body = lowerBlockToStmts(blockValues, scope);
  return [{ tag: 'loop', body } as IRLoop, pos];
}

function lowerLoopDialect(values: KtgValue[], scope: Scope, refinement?: string): IRDecl[] {
  let i = 0;
  let vars: IRParam[] = [];
  let source: 'range' | 'series' = 'range';
  let fromExpr: IRExpr = { tag: 'literal', type: 'integer!', value: 1 };
  let toExpr: IRExpr = { tag: 'literal', type: 'integer!', value: 0 };
  let stepExpr: IRExpr = { tag: 'literal', type: 'integer!', value: 1 };
  let seriesExpr: IRExpr | null = null;
  let guard: IRExpr | null = null;
  let body: IRStmt[] = [];

  while (i < values.length) {
    const v = values[i];

    if (v.type === 'word!' && v.name === 'for') {
      i++;
      if (values[i]?.type === 'block!') {
        const varBlock = values[i] as KtgBlock;
        vars = varBlock.values
          .filter(v => v.type === 'word!')
          .map(v => ({ name: (v as any).name, type: 'any!' as IRType }));
        i++;
      }
      continue;
    }

    if (v.type === 'word!' && v.name === 'in') {
      i++;
      source = 'series';
      if (values[i]) {
        const [expr, next] = lowerExpr(values, i, scope);
        seriesExpr = expr;
        i = next;
      }
      continue;
    }

    if (v.type === 'word!' && v.name === 'from') {
      i++;
      source = 'range';
      if (values[i]) {
        const [expr, next] = lowerExpr(values, i, scope);
        fromExpr = expr;
        i = next;
      }
      continue;
    }

    if (v.type === 'word!' && v.name === 'to') {
      i++;
      if (values[i]) {
        const [expr, next] = lowerExpr(values, i, scope);
        toExpr = expr;
        i = next;
      }
      continue;
    }

    if (v.type === 'word!' && v.name === 'by') {
      i++;
      if (values[i]) {
        const [expr, next] = lowerExpr(values, i, scope);
        stepExpr = expr;
        i = next;
      }
      continue;
    }

    if (v.type === 'word!' && v.name === 'when') {
      i++;
      if (values[i]?.type === 'block!') {
        const guardBlock = values[i] as KtgBlock;
        const guardStmts = lowerBlockToStmts(guardBlock.values, scope);
        // Extract the last expression as the guard condition
        const lastStmt = guardStmts[guardStmts.length - 1];
        if (lastStmt && lastStmt.tag === 'expr') {
          guard = (lastStmt as IRExprStmt).expr;
        } else if (lastStmt && lastStmt.tag === 'set') {
          guard = (lastStmt as IRSet).value;
        }
        i++;
      }
      continue;
    }

    if (v.type === 'block!') {
      body = lowerBlockToStmts((v as KtgBlock).values, scope);
      i++;
      continue;
    }

    i++;
  }

  if (vars.length === 0) vars = [{ name: 'it', type: 'any!' }];

  // Wrap body with guard if present
  if (guard) {
    body = [{
      tag: 'if',
      condition: guard,
      then: body,
    } as IRIf];
  }

  // Handle refinements: collect, fold, partition
  // These wrap the loop in accumulation logic
  if (refinement === 'collect') {
    return lowerLoopCollect(vars, source, fromExpr, toExpr, stepExpr, seriesExpr, body, scope);
  }
  if (refinement === 'fold') {
    return lowerLoopFold(vars, source, fromExpr, toExpr, stepExpr, seriesExpr, body, scope);
  }
  if (refinement === 'partition') {
    return lowerLoopPartition(vars, source, fromExpr, toExpr, stepExpr, seriesExpr, body, scope);
  }

  const loop = buildLoop(vars, source, fromExpr, toExpr, stepExpr, seriesExpr, body);
  return [loop];
}

function buildLoop(
  vars: IRParam[], source: string,
  fromExpr: IRExpr, toExpr: IRExpr, stepExpr: IRExpr,
  seriesExpr: IRExpr | null, body: IRStmt[],
): IRStmt {
  if (source === 'range') {
    return {
      tag: 'for-range', variable: vars[0].name, varType: vars[0].type,
      from: fromExpr, to: toExpr, step: stepExpr, body,
    } as IRForRange;
  }
  return {
    tag: 'for-each', variables: vars,
    source: seriesExpr ?? { tag: 'block', type: 'block!', elementType: 'any!', values: [] },
    stride: vars.length, body,
  } as IRForEach;
}

function lowerLoopCollect(
  vars: IRParam[], source: string,
  fromExpr: IRExpr, toExpr: IRExpr, stepExpr: IRExpr,
  seriesExpr: IRExpr | null, body: IRStmt[], scope: Scope,
): IRDecl[] {
  // _result: []
  // loop [...  append _result (body-result) ]
  // return _result
  const resultName = '__collect_result';
  const init: IRVarDecl = { tag: 'var', name: resultName, type: 'block!', value: { tag: 'block', type: 'block!', elementType: 'any!', values: [] } };

  // Wrap body: last expression gets appended to result
  const wrappedBody: IRStmt[] = [
    ...body,
    { tag: 'expr', expr: { tag: 'builtin', type: 'block!', name: 'append', args: [
      { tag: 'get', type: 'block!', name: resultName },
      { tag: 'get', type: 'any!', name: '__loop_val' },
    ] } } as IRExprStmt,
  ];

  // Actually, we need the body's result. Simpler: treat body as expression
  // and append it. Let's use a temp var.
  const collectBody: IRStmt[] = [
    { tag: 'set', name: '__loop_val', type: 'any!', value: body.length > 0 && body[body.length - 1].tag === 'expr'
      ? (body[body.length - 1] as IRExprStmt).expr
      : { tag: 'none', type: 'none!' } } as IRSet,
    { tag: 'expr', expr: { tag: 'builtin', type: 'block!', name: 'append', args: [
      { tag: 'get', type: 'block!', name: resultName },
      { tag: 'get', type: 'any!', name: '__loop_val' },
    ] } } as IRExprStmt,
  ];

  // Prepend non-last body stmts
  const bodyPrefix = body.slice(0, -1);
  const fullBody = [...bodyPrefix, ...collectBody];

  const loop = buildLoop(vars, source, fromExpr, toExpr, stepExpr, seriesExpr, fullBody);
  return [init, loop, { tag: 'expr', expr: { tag: 'get', type: 'block!', name: resultName } } as IRExprStmt];
}

function lowerLoopFold(
  vars: IRParam[], source: string,
  fromExpr: IRExpr, toExpr: IRExpr, stepExpr: IRExpr,
  seriesExpr: IRExpr | null, body: IRStmt[], scope: Scope,
): IRDecl[] {
  // For fold: first var is accumulator, rest are iteration vars.
  // First iteration skips body, acc = first value.
  // Subsequent iterations: acc = body result.
  const accName = vars[0].name;
  const iterVars = vars.slice(1);
  const iterVarName = iterVars.length > 0 ? iterVars[0].name : '__fold_n';

  if (source === 'range') {
    // acc = from; for n = from+step, to, step do acc = body end
    const init: IRVarDecl = { tag: 'var', name: accName, type: 'any!', value: fromExpr };

    // Body: set acc to result of body expression
    const lastStmt = body[body.length - 1];
    const bodyExpr = lastStmt?.tag === 'expr' ? (lastStmt as IRExprStmt).expr : { tag: 'none', type: 'none!' as const };
    const foldBody: IRStmt[] = [
      ...body.slice(0, -1),
      { tag: 'set', name: accName, type: 'any!', value: bodyExpr } as IRSet,
    ];

    // Start from second element: from + step
    const startExpr: IRExpr = { tag: 'binop', type: 'integer!', op: '+', left: fromExpr, right: stepExpr };

    const loop: IRForRange = {
      tag: 'for-range',
      variable: iterVarName,
      varType: 'any!',
      from: startExpr,
      to: toExpr,
      step: stepExpr,
      body: foldBody,
    };

    return [init, loop, { tag: 'expr', expr: { tag: 'get', type: 'any!', name: accName } } as IRExprStmt];
  }

  // Series fold: acc = first element, iterate rest
  const srcExpr = seriesExpr ?? { tag: 'block', type: 'block!' as const, elementType: 'any!' as const, values: [] };
  const init: IRVarDecl = {
    tag: 'var', name: accName, type: 'any!',
    value: { tag: 'index', type: 'any!', target: srcExpr, position: { tag: 'literal', type: 'integer!', value: 1 } },
  };

  const lastStmt = body[body.length - 1];
  const bodyExpr = lastStmt?.tag === 'expr' ? (lastStmt as IRExprStmt).expr : { tag: 'none', type: 'none!' as const };
  const foldBody: IRStmt[] = [
    ...body.slice(0, -1),
    { tag: 'set', name: accName, type: 'any!', value: bodyExpr } as IRSet,
  ];

  // Loop from index 2 to length, stride 1
  const loop: IRForRange = {
    tag: 'for-range',
    variable: '__fold_i',
    varType: 'integer!',
    from: { tag: 'literal', type: 'integer!', value: 2 },
    to: { tag: 'builtin', type: 'integer!', name: 'length?', args: [srcExpr] },
    step: { tag: 'literal', type: 'integer!', value: 1 },
    body: [
      { tag: 'set', name: iterVarName, type: 'any!',
        value: { tag: 'index', type: 'any!', target: srcExpr, position: { tag: 'get', type: 'integer!', name: '__fold_i' } } } as IRSet,
      ...foldBody,
    ],
  };

  return [init, loop, { tag: 'expr', expr: { tag: 'get', type: 'any!', name: accName } } as IRExprStmt];
}

function lowerLoopPartition(
  vars: IRParam[], source: string,
  fromExpr: IRExpr, toExpr: IRExpr, stepExpr: IRExpr,
  seriesExpr: IRExpr | null, body: IRStmt[], scope: Scope,
): IRDecl[] {
  const truthyName = '__partition_truthy';
  const falsyName = '__partition_falsy';
  const emptyBlock: IRExpr = { tag: 'block', type: 'block!', elementType: 'any!', values: [] };

  const init: IRDecl[] = [
    { tag: 'var', name: truthyName, type: 'block!', value: emptyBlock } as IRVarDecl,
    { tag: 'var', name: falsyName, type: 'block!', value: emptyBlock } as IRVarDecl,
  ];

  // Body evaluates to truthy/falsy, iteration value goes into the right bucket
  const iterVar = vars[0].name;
  const partitionBody: IRStmt[] = [
    ...body.slice(0, -1),
    {
      tag: 'if',
      condition: body.length > 0 && body[body.length - 1].tag === 'expr'
        ? (body[body.length - 1] as IRExprStmt).expr
        : { tag: 'literal', type: 'logic!', value: true },
      then: [{ tag: 'expr', expr: { tag: 'builtin', type: 'block!', name: 'append', args: [
        { tag: 'get', type: 'block!', name: truthyName },
        { tag: 'get', type: 'any!', name: iterVar },
      ] } } as IRExprStmt],
      else: [{ tag: 'expr', expr: { tag: 'builtin', type: 'block!', name: 'append', args: [
        { tag: 'get', type: 'block!', name: falsyName },
        { tag: 'get', type: 'any!', name: iterVar },
      ] } } as IRExprStmt],
    } as IRIf,
  ];

  const loop = buildLoop(vars, source, fromExpr, toExpr, stepExpr, seriesExpr, partitionBody);

  // Return [truthy, falsy] block
  const resultExpr: IRExpr = {
    tag: 'block', type: 'block!', elementType: 'block!',
    values: [
      { tag: 'get', type: 'block!', name: truthyName },
      { tag: 'get', type: 'block!', name: falsyName },
    ],
  };

  return [...init, loop, { tag: 'expr', expr: resultExpr } as IRExprStmt];
}

function lowerMatch(values: KtgValue[], pos: number, scope: Scope): [IRIf, number] {
  pos++; // skip 'match'
  const [matchValue, afterValue] = lowerExpr(values, pos, scope);
  const casesBlock = values[afterValue] as KtgBlock;
  pos = afterValue + 1;

  // Desugar to nested if/else chain
  // Store match value in a temp
  const ifChain = lowerMatchCases(matchValue, casesBlock.values, scope);
  return [ifChain, pos];
}

function lowerMatchCases(matchValue: IRExpr, cases: KtgValue[], scope: Scope): IRIf {
  let i = 0;
  const branches: { condition: IRExpr; bindings: IRStmt[]; guardExpr?: IRExpr; body: IRStmt[] }[] = [];
  let defaultBody: IRStmt[] | undefined;

  while (i < cases.length) {
    // default:
    if (cases[i].type === 'set-word!' && (cases[i] as any).name === 'default') {
      i++;
      if (cases[i]?.type === 'block!') {
        defaultBody = lowerBlockToStmts((cases[i] as KtgBlock).values, scope);
        i++;
      }
      continue;
    }

    // pattern block
    if (cases[i].type !== 'block!') { i++; continue; }
    const pattern = cases[i] as KtgBlock;
    i++;

    // when guard
    let guardExpr: IRExpr | undefined;
    if (i < cases.length && cases[i].type === 'word!' && (cases[i] as any).name === 'when') {
      i++;
      if (i < cases.length && cases[i].type === 'block!') {
        const guardStmts = lowerBlockToStmts((cases[i] as KtgBlock).values, scope);
        const lastStmt = guardStmts[guardStmts.length - 1];
        if (lastStmt?.tag === 'expr') guardExpr = (lastStmt as IRExprStmt).expr;
        i++;
      }
    }

    // body block
    if (i >= cases.length || cases[i].type !== 'block!') continue;
    const body = lowerBlockToStmts((cases[i] as KtgBlock).values, scope);
    i++;

    const { condition, bindings } = buildPatternMatch(matchValue, pattern, scope);
    branches.push({ condition, bindings, guardExpr, body });
  }

  if (branches.length === 0) {
    return { tag: 'if', condition: { tag: 'literal', type: 'logic!', value: false }, then: [] };
  }

  // Build nested if/else chain from bottom up
  let result: IRIf;
  const lastBranch = branches[branches.length - 1];
  const lastCond = lastBranch.guardExpr
    ? { tag: 'binop' as const, type: 'logic!' as IRType, op: 'and' as const, left: lastBranch.condition, right: lastBranch.guardExpr }
    : lastBranch.condition;
  result = {
    tag: 'if',
    condition: lastCond,
    then: [...lastBranch.bindings, ...lastBranch.body],
    else: defaultBody,
  };

  for (let j = branches.length - 2; j >= 0; j--) {
    const branch = branches[j];
    const cond = branch.guardExpr
      ? { tag: 'binop' as const, type: 'logic!' as IRType, op: 'and' as const, left: branch.condition, right: branch.guardExpr }
      : branch.condition;
    result = {
      tag: 'if',
      condition: cond,
      then: [...branch.bindings, ...branch.body],
      else: [result],
    };
  }

  return result;
}

function buildPatternMatch(matchValue: IRExpr, pattern: KtgBlock, scope: Scope): { condition: IRExpr; bindings: IRStmt[] } {
  const pv = pattern.values;

  // Single wildcard [_] — always matches
  if (pv.length === 1 && pv[0].type === 'word!' && (pv[0] as any).name === '_') {
    return { condition: { tag: 'literal', type: 'logic!', value: true }, bindings: [] };
  }

  // Single type match [integer!]
  if (pv.length === 1 && pv[0].type === 'word!' && (pv[0] as any).name.endsWith('!')) {
    return {
      condition: { tag: 'binop', type: 'logic!', op: '=',
        left: { tag: 'builtin', type: 'string!', name: 'type?', args: [matchValue] },
        right: { tag: 'literal', type: 'string!', value: (pv[0] as any).name },
      },
      bindings: [],
    };
  }

  // Single capture [x] — always matches, binds
  if (pv.length === 1 && pv[0].type === 'word!') {
    return {
      condition: { tag: 'literal', type: 'logic!', value: true },
      bindings: [{ tag: 'set', name: (pv[0] as any).name, type: 'any!', value: matchValue } as IRSet],
    };
  }

  // Single literal [42]
  if (pv.length === 1) {
    const [patExpr] = lowerAtom(pv, 0, scope);
    return {
      condition: { tag: 'binop', type: 'logic!', op: '=', left: matchValue, right: patExpr },
      bindings: [],
    };
  }

  // Multi-element: build conditions and bindings for each position
  const conditions: IRExpr[] = [];
  const bindings: IRStmt[] = [];

  for (let j = 0; j < pv.length; j++) {
    const p = pv[j];
    const elemAccess: IRExpr = { tag: 'index', type: 'any!', target: matchValue, position: { tag: 'literal', type: 'integer!', value: j + 1 } };

    if (p.type === 'word!' && (p as any).name === '_') {
      continue; // wildcard — no condition, no binding
    }
    if (p.type === 'word!' && (p as any).name.endsWith('!')) {
      // Type match at position
      conditions.push({ tag: 'binop', type: 'logic!', op: '=',
        left: { tag: 'builtin', type: 'string!', name: 'type?', args: [elemAccess] },
        right: { tag: 'literal', type: 'string!', value: (p as any).name },
      });
      continue;
    }
    if (p.type === 'word!') {
      // Capture
      bindings.push({ tag: 'set', name: (p as any).name, type: 'any!', value: elemAccess } as IRSet);
      continue;
    }
    // Literal match
    const [litExpr] = lowerAtom(pv, j, scope);
    conditions.push({ tag: 'binop', type: 'logic!', op: '=', left: elemAccess, right: litExpr });
  }

  // Also check length matches
  conditions.unshift({ tag: 'binop', type: 'logic!', op: '=',
    left: { tag: 'builtin', type: 'integer!', name: 'length?', args: [matchValue] },
    right: { tag: 'literal', type: 'integer!', value: pv.length },
  });

  // AND all conditions together
  let condition: IRExpr = conditions.length > 0
    ? conditions.reduce((acc, c) => ({ tag: 'binop', type: 'logic!', op: 'and', left: acc, right: c } as IRBinOp))
    : { tag: 'literal', type: 'logic!', value: true };

  return { condition, bindings };
}

function lowerTry(values: KtgValue[], pos: number, scope: Scope): [IRDecl, number] {
  pos++; // skip 'try'
  const block = values[pos] as KtgBlock;
  pos++;

  const body = lowerBlockToStmts(block.values, scope);

  // Generate a temp var for the result
  const resultVar = '__try_result_' + pos;

  return [{
    tag: 'try',
    body,
    resultVar,
  } as IRTry, pos];
}

function lowerTryHandle(values: KtgValue[], pos: number, scope: Scope): [IRDecl, number] {
  pos++; // skip 'try/handle' path

  // Consume the body block
  if (pos >= values.length || values[pos].type !== 'block!') {
    compileError('try/handle', 'expected a block');
  }
  const block = values[pos] as KtgBlock;
  pos++;

  // Consume the handler (a get-word referencing a function, or an inline function)
  const [handlerExpr, afterHandler] = lowerExpr(values, pos, scope);

  const body = lowerBlockToStmts(block.values, scope);

  // Desugar: try body, on error call handler with (kind, message, data)
  // and build a result! block
  return [{
    tag: 'try',
    body,
    handler: {
      kindVar: '__err_kind',
      messageVar: '__err_msg',
      dataVar: '__err_data',
      body: [
        { tag: 'set', name: '__handler_result', type: 'any!',
          value: { tag: 'call', type: 'any!', func: handlerExpr, args: [
            { tag: 'get', type: 'any!', name: '__err_kind' },
            { tag: 'get', type: 'any!', name: '__err_msg' },
            { tag: 'get', type: 'any!', name: '__err_data' },
          ] } } as any,
      ],
    },
    resultVar: '__try_result_' + pos,
  } as IRTry, afterHandler];
}

function lowerAttempt(values: KtgValue[], pos: number, scope: Scope): [IRDecl, number] {
  pos++; // skip 'attempt'
  const block = values[pos] as KtgBlock;
  pos++;

  // Parse the attempt dialect
  const bv = block.values;
  let hasSource = false;
  let sourceBlock: KtgValue[] | null = null;
  const steps: { type: 'then' | 'when'; values: KtgValue[] }[] = [];
  const handlers: { kind: string; values: KtgValue[] }[] = [];
  let fallbackValues: KtgValue[] | null = null;
  let retries = 0;

  let i = 0;
  while (i < bv.length) {
    const v = bv[i];
    if (v.type !== 'word!' && !(v.type === 'logic!' && v.value === true)) { i++; continue; }
    const name = v.type === 'word!' ? v.name : 'on';

    if (name === 'source' && i + 1 < bv.length && bv[i + 1].type === 'block!') {
      hasSource = true;
      sourceBlock = (bv[i + 1] as KtgBlock).values;
      i += 2;
    } else if (name === 'then' && i + 1 < bv.length && bv[i + 1].type === 'block!') {
      steps.push({ type: 'then', values: (bv[i + 1] as KtgBlock).values });
      i += 2;
    } else if (name === 'when' && i + 1 < bv.length && bv[i + 1].type === 'block!') {
      steps.push({ type: 'when', values: (bv[i + 1] as KtgBlock).values });
      i += 2;
    } else if (name === 'on' && i + 1 < bv.length && bv[i + 1].type === 'lit-word!' && i + 2 < bv.length && bv[i + 2].type === 'block!') {
      handlers.push({ kind: (bv[i + 1] as any).name, values: (bv[i + 2] as KtgBlock).values });
      i += 3;
    } else if (name === 'retries' && i + 1 < bv.length && bv[i + 1].type === 'integer!') {
      retries = (bv[i + 1] as any).value;
      i += 2;
    } else if (name === 'fallback' && i + 1 < bv.length && bv[i + 1].type === 'block!') {
      fallbackValues = (bv[i + 1] as KtgBlock).values;
      i += 2;
    } else {
      i++;
    }
  }

  // Build the pipeline body: source → then → then → ...
  const pipelineBody: IRStmt[] = [];

  if (hasSource && sourceBlock) {
    const sourceStmts = lowerBlockToStmts(sourceBlock, scope);
    // Last expression becomes 'it'
    const lastStmt = sourceStmts[sourceStmts.length - 1];
    const sourceExpr = lastStmt?.tag === 'expr' ? (lastStmt as IRExprStmt).expr
      : lastStmt?.tag === 'set' ? (lastStmt as IRSet).value
      : { tag: 'none', type: 'none!' } as IRNone;
    pipelineBody.push(...sourceStmts.slice(0, -1));
    pipelineBody.push({ tag: 'set', name: 'it', type: 'any!', value: sourceExpr } as IRSet);
  }

  for (const step of steps) {
    if (step.type === 'when') {
      const guardStmts = lowerBlockToStmts(step.values, scope);
      const lastGuard = guardStmts[guardStmts.length - 1];
      const guardExpr = lastGuard?.tag === 'expr' ? (lastGuard as IRExprStmt).expr
        : { tag: 'literal', type: 'logic!', value: true } as IRLiteral;
      pipelineBody.push({
        tag: 'if',
        condition: { tag: 'unary', type: 'logic!', op: 'not', operand: guardExpr } as IRUnaryOp,
        then: [{ tag: 'return', value: { tag: 'none', type: 'none!' } } as IRReturn],
      } as IRIf);
    } else {
      const thenStmts = lowerBlockToStmts(step.values, scope);
      const lastThen = thenStmts[thenStmts.length - 1];
      const thenExpr = lastThen?.tag === 'expr' ? (lastThen as IRExprStmt).expr
        : lastThen?.tag === 'set' ? (lastThen as IRSet).value
        : { tag: 'none', type: 'none!' } as IRNone;
      pipelineBody.push(...thenStmts.slice(0, -1));
      pipelineBody.push({ tag: 'set', name: 'it', type: 'any!', value: thenExpr } as IRSet);
    }
  }

  // Final: return it
  pipelineBody.push({ tag: 'return', value: { tag: 'get', type: 'any!', name: 'it' } } as IRReturn);

  if (!hasSource) {
    // No source → reusable function with 'it' as parameter
    const funcDecl: IRFuncDecl = {
      tag: 'func',
      name: '__attempt_pipeline',
      params: [{ name: 'it', type: 'any!' }],
      returnType: 'any!',
      body: pipelineBody,
    };
    return [funcDecl, pos];
  }

  // Has source → wrap in try, inline the pipeline
  if (handlers.length > 0 || fallbackValues) {
    const tryStmt: IRTry = {
      tag: 'try',
      body: pipelineBody,
      handler: handlers.length > 0 ? {
        kindVar: '__err_kind',
        messageVar: '__err_msg',
        dataVar: '__err_data',
        body: fallbackValues ? lowerBlockToStmts(fallbackValues, scope) : [],
      } : undefined,
    };
    return [tryStmt, pos];
  }

  // No error handling — just inline the pipeline
  return [{ tag: 'expr', expr: { tag: 'none', type: 'none!' } } as IRExprStmt, pos];
}

function lowerError(values: KtgValue[], pos: number, scope: Scope): [IRDecl, number] {
  pos++; // skip 'error'
  const args: IRExpr[] = [];
  for (let i = 0; i < 3 && pos < values.length; i++) {
    const [expr, nextPos] = lowerExpr(values, pos, scope);
    args.push(expr);
    pos = nextPos;
  }
  while (args.length < 3) args.push({ tag: 'none', type: 'none!' });

  return [{
    tag: 'throw',
    kind: args[0],
    message: args[1],
    data: args[2],
  } as IRThrow, pos];
}

// ============================================================
// Tier 3 — Homoiconic word lowering
// ============================================================

function lowerCompose(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'compose'
  if (pos >= values.length || values[pos].type !== 'block!') {
    compileError('compose', 'expected a block literal');
  }
  const block = values[pos] as KtgBlock;
  pos++;

  // Walk the block: plain values pass through, parens get lowered as expressions
  const resultValues: IRExpr[] = [];
  for (const v of block.values) {
    if (v.type === 'paren!') {
      // Lower the paren contents as an expression
      const innerDecls = lowerBlock((v as any).values, scope);
      const lastDecl = innerDecls[innerDecls.length - 1];
      if (lastDecl && lastDecl.tag === 'expr') {
        resultValues.push((lastDecl as IRExprStmt).expr);
      } else if (lastDecl && lastDecl.tag === 'var') {
        resultValues.push((lastDecl as IRVarDecl).value);
      } else {
        resultValues.push({ tag: 'none', type: 'none!' });
      }
    } else if (v.type === 'block!') {
      // Recurse into sub-blocks
      const [inner] = lowerCompose(
        [{ type: 'word!', name: 'compose' } as KtgValue, v],
        0, scope,
      );
      resultValues.push(inner);
    } else {
      // Literal value — pass through
      const [expr] = lowerAtom([v], 0, scope);
      resultValues.push(expr);
    }
  }

  const types = new Set(resultValues.map(v => v.type));
  const elementType: IRType = types.size === 1 ? [...types][0] as IRType : 'any!';
  return [{ tag: 'block', type: 'block!', elementType, values: resultValues }, pos];
}

function lowerReduce(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'reduce'
  if (pos >= values.length || values[pos].type !== 'block!') {
    compileError('reduce', 'reduce requires a literal block in compiled code — use #preprocess for dynamic blocks');
  }
  const block = values[pos] as KtgBlock;
  pos++;

  // Evaluate each expression group in the block
  const resultValues: IRExpr[] = [];
  const bv = block.values;
  let i = 0;
  while (i < bv.length) {
    const [expr, nextI] = lowerExpr(bv, i, scope);
    resultValues.push(expr);
    i = nextI;
  }

  const types = new Set(resultValues.map(v => v.type));
  const elementType: IRType = types.size === 1 ? [...types][0] as IRType : 'any!';
  return [{ tag: 'block', type: 'block!', elementType, values: resultValues }, pos];
}

function lowerBind(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'bind'
  // Consume both args, return the block unchanged.
  // In compiled code, bindings are already resolved by the compiler.
  const [blockExpr, afterBlock] = lowerExpr(values, pos, scope);
  const [_ctxExpr, afterCtx] = lowerExpr(values, afterBlock, scope);
  return [blockExpr, afterCtx];
}

function lowerWordsOf(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'words-of'
  const [ctxExpr, nextPos] = lowerExpr(values, pos, scope);

  // If the context is a literal make-context, we know the keys
  if (ctxExpr.tag === 'make-context') {
    const keys: IRExpr[] = ctxExpr.fields.map(f => ({
      tag: 'literal' as const, type: 'string!' as IRType, value: f.name,
    }));
    return [{ tag: 'block', type: 'block!', elementType: 'string!', values: keys }, nextPos];
  }

  // Runtime: emit helper call to get table keys
  return [{ tag: 'builtin', type: 'block!', name: 'words-of', args: [ctxExpr] }, nextPos];
}

function lowerAll(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'all'
  if (pos >= values.length || values[pos].type !== 'block!') {
    compileError('all', 'expected a block');
  }
  const block = values[pos] as KtgBlock;
  pos++;

  // Desugar: evaluate each expression, short-circuit with `and`
  const bv = block.values;
  const exprs: IRExpr[] = [];
  let i = 0;
  while (i < bv.length) {
    const [expr, nextI] = lowerExpr(bv, i, scope);
    exprs.push(expr);
    i = nextI;
  }

  if (exprs.length === 0) return [{ tag: 'literal', type: 'logic!', value: true }, pos];
  let result = exprs[0];
  for (let j = 1; j < exprs.length; j++) {
    result = { tag: 'binop', type: 'any!', op: 'and', left: result, right: exprs[j] };
  }
  return [result, pos];
}

function lowerAny(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'any'
  if (pos >= values.length || values[pos].type !== 'block!') {
    compileError('any', 'expected a block');
  }
  const block = values[pos] as KtgBlock;
  pos++;

  // Desugar: evaluate each expression, short-circuit with `or`
  const bv = block.values;
  const exprs: IRExpr[] = [];
  let i = 0;
  while (i < bv.length) {
    const [expr, nextI] = lowerExpr(bv, i, scope);
    exprs.push(expr);
    i = nextI;
  }

  if (exprs.length === 0) return [{ tag: 'none', type: 'none!' }, pos];
  let result = exprs[0];
  for (let j = 1; j < exprs.length; j++) {
    result = { tag: 'binop', type: 'any!', op: 'or', left: result, right: exprs[j] };
  }
  return [result, pos];
}

function lowerApply(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'apply'
  const [funcExpr, afterFunc] = lowerExpr(values, pos, scope);
  const [argsExpr, afterArgs] = lowerExpr(values, afterFunc, scope);

  // If args is a literal block, unpack to a direct call
  if (argsExpr.tag === 'block') {
    const funcRef = funcExpr.tag === 'get' ? funcExpr.name : funcExpr;
    return [{ tag: 'call', type: 'any!', func: funcRef as any, args: argsExpr.values }, afterArgs];
  }

  // Runtime: emit unpack call
  return [{ tag: 'builtin', type: 'any!', name: 'apply', args: [funcExpr, argsExpr] }, afterArgs];
}

function lowerSet(values: KtgValue[], pos: number, scope: Scope): [IRExpr, number] {
  pos++; // skip 'set'
  const [wordsExpr, afterWords] = lowerExpr(values, pos, scope);
  const [valuesExpr, afterValues] = lowerExpr(values, afterWords, scope);

  // If both are literal blocks, desugar to individual assignments
  // and return the values block
  if (wordsExpr.tag === 'block' && valuesExpr.tag === 'block') {
    // We can't emit multiple statements from an expression lowerer,
    // so emit as a builtin that the emitter handles specially
    return [{ tag: 'builtin', type: 'block!', name: 'set', args: [wordsExpr, valuesExpr] }, afterValues];
  }

  return [{ tag: 'builtin', type: 'block!', name: 'set', args: [wordsExpr, valuesExpr] }, afterValues];
}

// ============================================================
// Helpers
// ============================================================

function lowerBlockToStmts(values: KtgValue[], scope: Scope): IRStmt[] {
  // Extract lifecycle hooks before lowering
  const { body: bodyValues, enter, exit } = extractHooksFromValues(values);

  const decls = lowerBlock(bodyValues, scope);
  let stmts: IRStmt[] = decls.map(d => {
    if (d.tag === 'var') {
      return { tag: 'set', name: d.name, type: d.type, value: d.value } as IRSet;
    }
    if (d.tag === 'func') {
      return { tag: 'set', name: d.name, type: 'function!', value: {
        tag: 'make-closure',
        type: 'function!',
        params: d.params,
        returnType: d.returnType,
        captures: [],
        body: d.body,
      }} as IRSet;
    }
    return d as IRStmt;
  });

  // If hooks present, wrap in try/finally
  if (enter || exit) {
    const enterStmts = enter ? lowerBlockToStmts(enter, scope) : [];
    const exitStmts = exit ? lowerBlockToStmts(exit, scope) : [];
    stmts = [
      ...enterStmts,
      { tag: 'try', body: stmts, finally: exitStmts } as IRTry,
    ];
  }

  return stmts;
}

function extractHooksFromValues(values: KtgValue[]): {
  body: KtgValue[];
  enter: KtgValue[] | null;
  exit: KtgValue[] | null;
} {
  let enter: KtgValue[] | null = null;
  let exit: KtgValue[] | null = null;
  const body: KtgValue[] = [];
  let i = 0;

  while (i < values.length) {
    const v = values[i];
    if (v.type === 'meta-word!' && v.name === 'enter' && i + 1 < values.length && values[i + 1].type === 'block!') {
      enter = (values[i + 1] as KtgBlock).values;
      i += 2;
    } else if (v.type === 'meta-word!' && v.name === 'exit' && i + 1 < values.length && values[i + 1].type === 'block!') {
      exit = (values[i + 1] as KtgBlock).values;
      i += 2;
    } else {
      body.push(v);
      i++;
    }
  }

  return { body, enter, exit };
}

function lowerBlockLiteral(block: KtgBlock, scope: Scope): IRBlockLiteral {
  const values: IRExpr[] = block.values.map(v => {
    switch (v.type) {
      case 'integer!': return { tag: 'literal', type: 'integer!', value: v.value } as IRLiteral;
      case 'float!': return { tag: 'literal', type: 'float!', value: v.value } as IRLiteral;
      case 'string!': return { tag: 'literal', type: 'string!', value: v.value } as IRLiteral;
      case 'logic!': return { tag: 'literal', type: 'logic!', value: v.value } as IRLiteral;
      case 'word!': return { tag: 'literal', type: 'word!', value: v.name } as IRLiteral;
      case 'set-word!': return { tag: 'literal', type: 'word!', value: v.name } as IRLiteral;
      case 'lit-word!': return { tag: 'literal', type: 'lit-word!', value: v.name } as IRLiteral;
      case 'meta-word!': return { tag: 'literal', type: 'meta-word!', value: v.name } as IRLiteral;
      case 'none!': return { tag: 'none', type: 'none!' } as IRNone;
      default: return { tag: 'none', type: 'none!' } as IRNone;
    }
  });

  // Infer element type
  const types = new Set(values.map(v => v.type));
  const elementType: IRType = types.size === 1 ? [...types][0] as IRType : 'any!';

  return { tag: 'block', type: 'block!', elementType, values };
}

function inferBinopType(op: string, leftType: IRType, rightType: IRType): IRType {
  // Comparison ops always return logic
  if (['=', '<>', '<', '>', '<=', '>='].includes(op)) return 'logic!';
  // Division always returns float
  if (op === '/') return 'float!';
  // If both are known and same numeric type
  if (leftType === 'integer!' && rightType === 'integer!') return 'integer!';
  if (leftType === 'float!' || rightType === 'float!') return 'float!';
  // String concatenation
  if (op === '+' && (leftType === 'string!' || rightType === 'string!')) return 'string!';
  return 'any!';
}
