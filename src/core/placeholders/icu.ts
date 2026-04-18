import type { ICUPlaceholder } from './types.js';

const ICU_PLACEHOLDER_NAME_PATTERN = /[\w.-]+/u;
const ICU_SIMPLE_PLACEHOLDER_PATTERN = /\{([\w.-]+)\}/gu;
const ICU_PLURAL_PATTERN = /\{\s*[\w.-]+\s*,\s*plural\s*,/u;

export interface ICUPlaceholderMatch {
  end: number;
  name: string;
  start: number;
}

export function containsPluralSyntax(text: string): boolean {
  return ICU_PLURAL_PATTERN.test(text);
}

export function extractIcuPlaceholderMatches(text: string): ICUPlaceholderMatch[] {
  const matches: ICUPlaceholderMatch[] = [];

  for (const match of text.matchAll(ICU_SIMPLE_PLACEHOLDER_PATTERN)) {
    const name = match[1];
    const start = match.index;

    if (!name || start === undefined) {
      continue;
    }

    matches.push({
      end: start + match[0].length,
      name,
      start,
    });
  }

  return matches;
}

export function extractIcuPlaceholderNames(text: string): string[] {
  return extractIcuPlaceholderMatches(text).map((match) => match.name);
}

export function extractUniqueIcuPlaceholders(
  text: string,
  placeholderTypes: ReadonlyMap<string, ICUPlaceholder['type']> = new Map(),
): ICUPlaceholder[] {
  const seen = new Set<string>();
  const placeholders: ICUPlaceholder[] = [];

  for (const name of extractIcuPlaceholderNames(text)) {
    if (seen.has(name)) {
      continue;
    }

    seen.add(name);
    placeholders.push({
      name,
      type: placeholderTypes.get(name) ?? 'string',
    });
  }

  return placeholders;
}

export function isSupportedIcuPlaceholderName(name: string): boolean {
  return ICU_PLACEHOLDER_NAME_PATTERN.test(name);
}
