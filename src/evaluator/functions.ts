import { KtgContext } from './context';
import {
  KtgValue, KtgBlock, KtgFunction, FuncSpec,
  KtgError,
} from './values';

export function parseSpec(specBlock: KtgBlock): FuncSpec {
  const params: FuncSpec['params'] = [];
  const refinements: FuncSpec['refinements'] = [];
  let returnType: string | undefined;

  let currentRefinement: FuncSpec['refinements'][0] | null = null;
  const values = specBlock.values;

  for (let i = 0; i < values.length; i++) {
    const v = values[i];

    // Return type annotation: "return:" followed by a block with type
    if (v.type === 'set-word!' && v.name === 'return') {
      const next = values[i + 1];
      if (next && next.type === 'block!' && next.values.length > 0) {
        const typeVal = next.values[0];
        if (typeVal.type === 'word!') returnType = typeVal.name;
        i++;
      }
      continue;
    }

    // Refinement: operator "/" followed by a word
    if (v.type === 'operator!' && (v as any).symbol === '/' && i + 1 < values.length && values[i + 1].type === 'word!') {
      i++;
      const refName = (values[i] as any).name;
      currentRefinement = { name: refName, params: [] };
      refinements.push(currentRefinement);
      continue;
    }

    // Skip strings (documentation)
    if (v.type === 'string!') continue;

    // Skip type constraint blocks (they follow a param word)
    if (v.type === 'block!') continue;

    // Param word
    if (v.type === 'word!') {
      const name = v.name;
      let typeConstraint: string | undefined;

      // Check if next value is a type constraint block [type!] or [block! element-type!]
      let elementType: string | undefined;
      const next = values[i + 1];
      if (next && next.type === 'block!' && next.values.length > 0) {
        const typeVal = next.values[0];
        if (typeVal.type === 'word!') typeConstraint = typeVal.name;
        if (next.values.length > 1 && next.values[1].type === 'word!') {
          elementType = (next.values[1] as any).name;
        }
        i++;
      }

      if (currentRefinement) {
        currentRefinement.params.push({ name, typeConstraint, elementType });
      } else {
        params.push({ name, typeConstraint, elementType });
      }
    }
  }

  return { params, refinements, returnType };
}

export function createFunction(specVal: KtgValue, bodyVal: KtgValue, closure: KtgContext): KtgFunction {
  if (specVal.type !== 'block!') throw new KtgError('type', 'function spec must be a block');
  if (bodyVal.type !== 'block!') throw new KtgError('type', 'function body must be a block');

  const spec = parseSpec(specVal);
  return {
    type: 'function!',
    spec,
    body: bodyVal,
    closure,
  };
}
