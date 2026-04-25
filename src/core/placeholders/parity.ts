import type { SourceKey } from '../store/schemas.js';
import { extractIcuPlaceholderMatches } from './icu.js';

interface PlaceholderSignature {
  /** Placeholder names in extraction order. */
  ordered: string[];
  /** Frequency map: how many times each name appears. */
  counts: Map<string, number>;
  /** Sorted type signature string for each unique name. */
  types: string;
}

function buildPlaceholderSignature(source: SourceKey, text: string): PlaceholderSignature {
  const matches = extractIcuPlaceholderMatches(text);
  const ordered = matches.map((match) => match.name);

  const counts = new Map<string, number>();
  for (const name of ordered) {
    counts.set(name, (counts.get(name) ?? 0) + 1);
  }

  const typeLookup = new Map(
    Object.entries(source.placeholders).map(([name, placeholder]) => [name, placeholder.type]),
  );
  const types = [...counts.keys()]
    .sort()
    .map((name) => `${name}:${typeLookup.get(name) ?? 'string'}`)
    .join('|');

  return { counts, ordered, types };
}

function areMapsEqual(a: Map<string, number>, b: Map<string, number>): boolean {
  if (a.size !== b.size) {
    return false;
  }

  for (const [key, value] of a) {
    if (b.get(key) !== value) {
      return false;
    }
  }

  return true;
}

export function hasPlaceholderParity(source: SourceKey, targetText: string): boolean {
  const sourceSig = buildPlaceholderSignature(source, source.text);
  const targetSig = buildPlaceholderSignature(source, targetText);

  if (sourceSig.ordered.length !== targetSig.ordered.length) {
    return false;
  }

  if (!areMapsEqual(sourceSig.counts, targetSig.counts)) {
    return false;
  }

  if (sourceSig.types !== targetSig.types) {
    return false;
  }

  const sourcePositional = sourceSig.ordered.filter((name) => /^\d+$/u.test(name));
  const targetPositional = targetSig.ordered.filter((name) => /^\d+$/u.test(name));

  return sourcePositional.join('|') === targetPositional.join('|');
}
