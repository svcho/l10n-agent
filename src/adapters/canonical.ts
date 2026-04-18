import { extractUniqueIcuPlaceholders } from '../core/placeholders/icu.js';
import type { ICUPlaceholder } from '../core/placeholders/types.js';
import type { SourceFile, TranslationFile } from '../core/store/schemas.js';
import type { CanonicalKeySet } from './base.js';

export interface CanonicalKeyValue {
  comment?: string;
  placeholders: ICUPlaceholder[];
  text: string;
}

export interface ExtendedCanonicalKeySet extends CanonicalKeySet {
  keys: Map<string, CanonicalKeyValue>;
}

export function buildCanonicalKeySetFromSource(source: SourceFile): ExtendedCanonicalKeySet {
  const keys = new Map<string, CanonicalKeyValue>();

  for (const [key, value] of Object.entries(source.keys)) {
    const placeholderTypes = new Map(
      Object.entries(value.placeholders).map(([name, placeholder]) => [name, placeholder.type]),
    );

    const placeholdersFromText = extractUniqueIcuPlaceholders(value.text, placeholderTypes);
    const remainingDeclaredPlaceholders = Object.entries(value.placeholders)
      .filter(([name]) => !placeholdersFromText.some((placeholder) => placeholder.name === name))
      .map(([name, placeholder]) => ({
        name,
        type: placeholder.type,
      }));

    const canonicalValue: CanonicalKeyValue = {
      placeholders: [...placeholdersFromText, ...remainingDeclaredPlaceholders],
      text: value.text,
    };

    keys.set(
      key,
      value.description
        ? {
            ...canonicalValue,
            comment: value.description,
          }
        : canonicalValue,
    );
  }

  return { keys };
}

export function buildCanonicalKeySetFromTranslation(
  translation: TranslationFile,
  source: SourceFile,
): CanonicalKeySet {
  const keys = new Map<string, CanonicalKeyValue>();

  for (const [key, entry] of Object.entries(translation.entries)) {
    const sourceKey = source.keys[key];
    const declaredPlaceholders = Object.entries(sourceKey?.placeholders ?? {}).map(([name, value]) => ({
      name,
      type: value.type,
    }));
    const placeholderTypes = new Map(declaredPlaceholders.map((placeholder) => [placeholder.name, placeholder.type]));
    const placeholdersFromText = extractUniqueIcuPlaceholders(entry.text, placeholderTypes);
    const remainingDeclaredPlaceholders = declaredPlaceholders.filter(
      (placeholder) => !placeholdersFromText.some((candidate) => candidate.name === placeholder.name),
    );

    keys.set(key, {
      placeholders: [...placeholdersFromText, ...remainingDeclaredPlaceholders],
      text: entry.text,
    });
  }

  return { keys };
}

export function compareCanonicalKeySets(
  expected: CanonicalKeySet,
  actual: CanonicalKeySet,
  details: {
    locale: string;
    path: string;
    platform: 'ios' | 'android';
  },
): Array<{
  code: string;
  details: Record<string, string | number | boolean | undefined>;
  level: 'error';
  next: string;
  summary: string;
}> {
  const diagnostics: Array<{
    code: string;
    details: Record<string, string | number | boolean | undefined>;
    level: 'error';
    next: string;
    summary: string;
  }> = [];

  for (const [key, expectedValue] of expected.keys.entries()) {
    const actualValue = actual.keys.get(key);
    if (!actualValue) {
      diagnostics.push({
        code: 'L10N_E0066',
        details: { ...details, key },
        level: 'error',
        next: 'Rebuild the platform catalog from the canonical store.',
        summary: 'Platform localization is missing a canonical key',
      });
      continue;
    }

    if (actualValue.text !== expectedValue.text) {
      diagnostics.push({
        code: 'L10N_E0067',
        details: { ...details, key },
        level: 'error',
        next: 'Regenerate the platform file so the text matches the canonical store.',
        summary: 'Platform localization text is out of sync with the canonical store',
      });
    }

    const expectedPlaceholderSignature = expectedValue.placeholders
      .map((placeholder) => `${placeholder.name}:${placeholder.type}`)
      .sort()
      .join('|');
    const actualPlaceholderSignature = actualValue.placeholders
      .map((placeholder) => `${placeholder.name}:${placeholder.type}`)
      .sort()
      .join('|');

    if (expectedPlaceholderSignature !== actualPlaceholderSignature) {
      diagnostics.push({
        code: 'L10N_E0041',
        details: { ...details, key },
        level: 'error',
        next: 'Regenerate the platform file so its placeholders match the canonical store.',
        summary: 'Platform localization placeholders do not match the canonical store',
      });
    }
  }

  for (const key of actual.keys.keys()) {
    if (!expected.keys.has(key)) {
      diagnostics.push({
        code: 'L10N_E0068',
        details: { ...details, key },
        level: 'error',
        next: 'Remove the extra platform key or restore it in the canonical store.',
        summary: 'Platform localization contains a key missing from the canonical store',
      });
    }
  }

  return diagnostics;
}
