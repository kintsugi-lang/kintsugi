import { compileToLua } from '@/compiler/compile';
import { readFileSync, writeFileSync } from 'fs';
import { resolve } from 'path';

const args = process.argv.slice(2);

if (args.length === 0) {
  console.log('Kintsugi Compiler');
  console.log('');
  console.log('Usage: bun run compile.ts <file.ktg> [--output path]');
  console.log('');
  console.log('Target is detected from the file header:');
  console.log('  Kintsugi/Lua [...]  → .lua');
  console.log('  Kintsugi/JS [...]   → .js (not yet implemented)');
  process.exit(1);
}

const filePath = resolve(args[0]);

let source: string;
try {
  source = readFileSync(filePath, 'utf-8');
} catch {
  console.error(`Error: Cannot read file '${filePath}'`);
  process.exit(1);
}

function detectDialect(src: string): string {
  const match = src.match(/^\s*Kintsugi\/(\w+)\s*\[/m);
  if (match) return match[1].toLowerCase();
  return 'script';
}

const dialect = detectDialect(source);

switch (dialect) {
  case 'lua': {
    try {
      const lua = compileToLua(source);
      const outPath = args.includes('--output')
        ? resolve(args[args.indexOf('--output') + 1])
        : filePath.replace(/\.ktg$/, '.lua');
      writeFileSync(outPath, lua);
      console.log(outPath);
    } catch (e: any) {
      if (e.name === 'CompileError') {
        console.error(`Compile error: ${e.message}`);
      } else if (e.name === 'ParseError') {
        console.error(`Parse error: ${e.message}`);
      } else {
        console.error(`Internal error: ${e.message}`);
      }
      process.exit(1);
    }
    break;
  }

  case 'js':
    console.error('Kintsugi/JS backend not yet implemented');
    process.exit(1);
    break;

  case 'script':
    console.error('No compilation target. Add a header: Kintsugi/Lua [...]');
    process.exit(1);
    break;

  default:
    console.error(`Unknown dialect: ${dialect}`);
    process.exit(1);
}
