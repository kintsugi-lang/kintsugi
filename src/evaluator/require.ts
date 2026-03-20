import { KtgContext } from './context';
import {
  KtgValue, KtgBlock,
  NONE, KtgError, valueToString,
} from './values';
import type { Evaluator } from './evaluator';
import { readFileSync } from 'fs';
import { parseString } from '@/helpers';
import { astToValue } from './values';

interface ModuleCache {
  contexts: Map<string, KtgValue>;
  headers: Map<string, KtgValue>;
}

const globalCache: ModuleCache = {
  contexts: new Map(),
  headers: new Map(),
};

const loading: Set<string> = new Set();

export function requireModule(
  filePath: string,
  evaluator: Evaluator,
  callerCtx: KtgContext,
  headerOnly: boolean,
): KtgValue {
  // Circular dependency check
  if (!headerOnly && loading.has(filePath)) {
    throw new KtgError('require', `Circular dependency detected: ${filePath}`);
  }

  // Check cache
  if (headerOnly && globalCache.headers.has(filePath)) {
    return globalCache.headers.get(filePath)!;
  }
  if (!headerOnly && globalCache.contexts.has(filePath)) {
    return globalCache.contexts.get(filePath)!;
  }

  // Read and parse file
  let source: string;
  try {
    source = readFileSync(filePath, 'utf-8');
  } catch {
    throw new KtgError('file', `Cannot read file: ${filePath}`);
  }

  const ast = parseString(source);
  const block = astToValue(ast) as KtgBlock;
  const values = block.values;

  // Check for header: first value is word 'Kintsugi', second is a block
  let header: KtgBlock | null = null;
  let bodyStart = 0;

  if (values.length >= 2
    && values[0].type === 'word!' && values[0].name === 'Kintsugi'
    && values[1].type === 'block!') {
    header = values[1] as KtgBlock;
    bodyStart = 2;
  }

  // Parse header for metadata
  const headerInfo = header ? parseHeader(header) : null;

  // Cache header result
  const headerResult = header ? header : NONE;
  globalCache.headers.set(filePath, headerResult);

  if (headerOnly) {
    return headerResult;
  }

  // Mark as loading for circular dependency detection
  loading.add(filePath);

  try {
    // Create isolated context for the module
    const moduleCtx = new KtgContext(evaluator.global);

    // Resolve module dependencies from header
    if (headerInfo?.modules) {
      for (const dep of headerInfo.modules) {
        const depCtx = requireModule(dep.path, evaluator, moduleCtx, false);
        moduleCtx.set(dep.name, depCtx);
      }
    }

    // Evaluate body
    const bodyBlock: KtgBlock = {
      type: 'block!',
      values: values.slice(bodyStart),
    };
    evaluator.evalBlock(bodyBlock, moduleCtx);

    // Build result context, applying exports filter
    let resultCtx: KtgValue;
    if (headerInfo?.exports) {
      // Exports declared: only expose listed words
      const filtered = new KtgContext();
      for (const name of headerInfo.exports) {
        const val = moduleCtx.get(name);
        if (val !== undefined) filtered.set(name, val);
      }
      resultCtx = { type: 'context!', context: filtered };
    } else {
      // No exports: everything is public
      resultCtx = { type: 'context!', context: moduleCtx };
    }

    globalCache.contexts.set(filePath, resultCtx);
    return resultCtx;
  } finally {
    loading.delete(filePath);
  }
}

interface HeaderInfo {
  name?: string;
  version?: string;
  exports?: string[];
  modules?: { name: string; path: string }[];
}

function parseHeader(header: KtgBlock): HeaderInfo {
  const info: HeaderInfo = {};
  const vals = header.values;

  for (let i = 0; i < vals.length - 1; i++) {
    if (vals[i].type !== 'set-word!') continue;
    const key = (vals[i] as any).name;
    const val = vals[i + 1];

    switch (key) {
      case 'name':
        if (val.type === 'lit-word!') info.name = val.name;
        break;
      case 'version':
        if (val.type === 'tuple!') info.version = val.parts.join('.');
        break;
      case 'exports':
        if (val.type === 'block!') {
          info.exports = val.values
            .filter((v): v is any => v.type === 'word!' || v.type === 'lit-word!')
            .map(v => v.name);
        }
        break;
      case 'modules':
        if (val.type === 'block!') {
          info.modules = [];
          for (const mv of val.values) {
            if (mv.type === 'file!') {
              // Extract name from filename: %lib/math.ktg → math
              const name = mv.value
                .replace(/^.*\//, '')  // strip path
                .replace(/\.ktg$/, ''); // strip extension
              info.modules.push({ name, path: mv.value });
            }
          }
        }
        break;
    }
  }

  return info;
}

export function resetRequireCache(): void {
  globalCache.contexts.clear();
  globalCache.headers.clear();
  loading.clear();
}
