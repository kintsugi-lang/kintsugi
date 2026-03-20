import { lower } from './lower';
import { emitLua } from './emit-lua';
import type { EmitResult } from './emit-lua';

export function compileToLua(source: string): string {
  const ir = lower(source);
  const result = emitLua(ir);
  // Print warnings to stderr
  for (const warning of result.warnings) {
    console.error(warning);
  }
  return result.code;
}

export function compileToLuaWithWarnings(source: string): EmitResult {
  const ir = lower(source);
  return emitLua(ir);
}
