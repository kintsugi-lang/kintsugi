// ============================================================
// Kintsugi Intermediate Representation
// ============================================================
//
// The IR sits between the Kintsugi AST (after preprocessing)
// and the backend code emitters (JS, Lua, WASM).
//
// Design principles:
//   - Every node carries a type (inferred or explicit, default: any!)
//   - Dialects are desugared to primitive control flow
//   - No word lookup — all names are resolved
//   - No infix — all operations are explicit
//   - Backends read the IR and emit target code
//   - Dynamic backends (JS, Lua) ignore types
//   - Static backends (WASM) use types to optimize
//
// Compilation tiers:
//   Tier 1 — Trivial translation: variables, arithmetic, functions,
//            if/either, loops, blocks, contexts, strings, errors
//   Tier 2 — Desugared: match → if chains, attempt → func + try,
//            loop refinements → loop + accumulator, rejoin → concat
//   Tier 3 — Runtime library: parse, compose, bind, reduce, do
//            These ship as library functions in the target language.

// ============================================================
// Types
// ============================================================

export type IRType =
  | 'any!'
  | 'integer!'
  | 'float!'
  | 'string!'
  | 'logic!'
  | 'none!'
  | 'block!'
  | 'context!'
  | 'function!'
  | 'pair!'
  | 'tuple!'
  | 'date!'
  | 'time!'
  | 'file!'
  | 'url!'
  | 'email!'
  | 'map!'
  | 'word!'
  | 'lit-word!'
  | 'meta-word!';

export type IRParam = { name: string; type: IRType };

// ============================================================
// Expressions — produce a value
// ============================================================

export type IRExpr =
  | IRLiteral
  | IRGet
  | IRCall
  | IRBuiltinCall
  | IRBinOp
  | IRUnaryOp
  | IRBlockLiteral
  | IRIndex
  | IRFieldGet
  | IRMakeContext
  | IRMakeClosure
  | IRInlineIf
  | IRNone;

export type IRLiteral = {
  tag: 'literal';
  type: IRType;
  value: string | number | boolean;
};

export type IRGet = {
  tag: 'get';
  type: IRType;
  name: string;
};

// User-defined function call
export type IRCall = {
  tag: 'call';
  type: IRType;
  func: string | IRExpr;
  args: IRExpr[];
  refinements?: string[];
};

// Built-in / native call — backend maps name to target implementation
export type IRBuiltinCall = {
  tag: 'builtin';
  type: IRType;
  name: string;
  args: IRExpr[];
  refinements?: string[];
};

export type IRBinOp = {
  tag: 'binop';
  type: IRType;
  op: '+' | '-' | '*' | '/' | '%'
    | '=' | '<>' | '<' | '>' | '<=' | '>='
    | 'and' | 'or';
  left: IRExpr;
  right: IRExpr;
};

export type IRUnaryOp = {
  tag: 'unary';
  type: IRType;
  op: 'not' | 'negate';
  operand: IRExpr;
};

export type IRBlockLiteral = {
  tag: 'block';
  type: 'block!';
  elementType: IRType;   // type of elements, 'any!' if mixed
  values: IRExpr[];
};

export type IRIndex = {
  tag: 'index';
  type: IRType;
  target: IRExpr;
  position: IRExpr;      // 1-based in IR, backend converts
};

export type IRFieldGet = {
  tag: 'field-get';
  type: IRType;
  target: IRExpr;
  field: string;
};

// context [x: 10 y: 20] → explicit key-value construction
export type IRMakeContext = {
  tag: 'make-context';
  type: 'context!';
  fields: { name: string; type: IRType; value: IRExpr }[];
};

// Closure — a function that captures variables from its defining scope
export type IRMakeClosure = {
  tag: 'make-closure';
  type: 'function!';
  params: IRParam[];
  returnType: IRType;
  captures: { name: string; type: IRType }[];
  body: IRStmt[];
};

export type IRInlineIf = {
  tag: 'inline-if';
  type: IRType;
  condition: IRExpr;
  then: IRStmt[];
  else?: IRStmt[];
};

export type IRNone = {
  tag: 'none';
  type: 'none!';
};

// ============================================================
// Statements — perform actions
// ============================================================

export type IRStmt =
  | IRSet
  | IRReturn
  | IRIf
  | IRLoop
  | IRForRange
  | IRForEach
  | IRBreak
  | IRExprStmt
  | IRFieldSet
  | IRTry
  | IRThrow;

export type IRSet = {
  tag: 'set';
  name: string;
  type: IRType;
  value: IRExpr;
};

export type IRReturn = {
  tag: 'return';
  value: IRExpr;
};

export type IRIf = {
  tag: 'if';
  condition: IRExpr;
  then: IRStmt[];
  else?: IRStmt[];
};

export type IRLoop = {
  tag: 'loop';
  body: IRStmt[];
};

export type IRForRange = {
  tag: 'for-range';
  variable: string;
  varType: IRType;
  from: IRExpr;
  to: IRExpr;
  step: IRExpr;
  body: IRStmt[];
};

export type IRForEach = {
  tag: 'for-each';
  variables: IRParam[];
  source: IRExpr;
  stride: number;
  body: IRStmt[];
};

export type IRBreak = {
  tag: 'break';
};

export type IRExprStmt = {
  tag: 'expr';
  expr: IRExpr;
};

export type IRFieldSet = {
  tag: 'field-set';
  target: IRExpr;
  field: string;
  value: IRExpr;
};

export type IRTry = {
  tag: 'try';
  body: IRStmt[];
  handler?: {
    kindVar: string;
    messageVar: string;
    dataVar: string;
    body: IRStmt[];
  };
  finally?: IRStmt[];      // @exit desugars here — always runs
  resultVar?: string;      // if present, try assigns result! to this var
};

export type IRThrow = {
  tag: 'throw';
  kind: IRExpr;
  message: IRExpr;
  data: IRExpr;
};

// ============================================================
// Top-level declarations
// ============================================================

export type IRDecl =
  | IRFuncDecl
  | IRVarDecl
  | IRStmt;

export type IRFuncDecl = {
  tag: 'func';
  name: string;
  params: IRParam[];
  returnType: IRType;
  body: IRStmt[];
  captures?: { name: string; type: IRType }[];
  refinements?: {
    name: string;
    params: IRParam[];
  }[];
};

export type IRVarDecl = {
  tag: 'var';
  name: string;
  type: IRType;
  value: IRExpr;
};

// ============================================================
// Module — the top-level compilation unit
// ============================================================

export type IRModule = {
  name: string;
  dialect: 'script' | 'js' | 'lua' | 'wasm';
  exports: string[];       // empty = everything public
  imports: IRImport[];     // modules this depends on
  declarations: IRDecl[];
};

export type IRImport = {
  name: string;            // local binding name
  path: string;            // file path
  dialect: string;         // target dialect of the imported module
};

// ============================================================
// Tier 3 — Runtime library calls
// ============================================================
// These are emitted as IRBuiltinCall with specific names.
// Each backend provides implementations.
//
// Runtime builtins:
//   __parse_block(input, rules)     — block parsing
//   __parse_string(input, rules)    — string parsing
//   __compose(block)                — compose with paren evaluation
//   __bind(block, context)          — rebind words
//   __reduce(block)                 — evaluate block, return results
//   __do(block)                     — evaluate block as code
//   __make_result(ok, value, kind, message, data) — construct result! block
//
// Standard builtins (Tier 1, but still emitted as builtin calls):
//   __print(value)
//   __probe(value)
//   __length(series)
//   __append(series, value)
//   __copy(series)
//   __first(series), __last(series), __pick(series, index)
//   __trim(string), __uppercase(string), __lowercase(string)
//   __join(a, b), __split(string, delim)
//   __type_of(value)
//   __to(target_type, value)
//   ... etc
