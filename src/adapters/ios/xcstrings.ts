import { access, constants } from 'node:fs/promises';

import type { KeyTransform } from '../../config/schema.js';
import { L10nError } from '../../errors/l10n-error.js';
import {
  containsPluralSyntax,
  extractUniqueIcuPlaceholders,
} from '../../core/placeholders/icu.js';
import type { ICUPlaceholder } from '../../core/placeholders/types.js';
import type { SourceFile, TranslationFile } from '../../core/store/schemas.js';
import { readJsonFile, writeJsonFileAtomic } from '../../utils/fs.js';
import type { Adapter, CanonicalKeySet } from '../base.js';

interface XCStringsCatalog {
  sourceLanguage: string;
  strings: Record<string, XCStringsEntry>;
  version: string;
}

interface XCStringsEntry {
  comment?: string;
  extractionState?: string;
  localizations?: Record<string, XCStringsLocalization>;
  shouldTranslate?: boolean;
}

interface XCStringsLocalization {
  stringUnit?: XCStringsStringUnit;
  substitutions?: Record<string, XCStringsSubstitution>;
  variations?: {
    device?: Record<string, unknown>;
    plural?: Record<string, unknown>;
  };
}

interface XCStringsStringUnit {
  state: string;
  value: string;
}

interface XCStringsSubstitution {
  argNum?: number;
  formatSpecifier?: string;
  variations?: {
    device?: Record<string, unknown>;
    plural?: Record<string, unknown>;
  };
}

interface CanonicalKeyValue {
  comment?: string;
  placeholders: ICUPlaceholder[];
  text: string;
}

type ExtendedCanonicalKeySet = {
  keys: Map<string, CanonicalKeyValue>;
};

const IOS_FORMAT_TOKEN_PATTERN = /%(#@([\w.-]+)@|(?:(\d+)\$)?(?:@|lld|ld|d|f))/gu;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function mapKeyTransform(keyTransform: KeyTransform): { fromCanonical: string; toCanonical: string } {
  switch (keyTransform) {
    case 'identity':
      return { fromCanonical: '.', toCanonical: '.' };
    case 'snake_case':
      return { fromCanonical: '_', toCanonical: '_' };
    case 'kebab-case':
      return { fromCanonical: '-', toCanonical: '-' };
    default:
      return { fromCanonical: '.', toCanonical: '.' };
  }
}

function buildUnsupportedPluralError(path: string, key: string, locale: string): L10nError {
  return new L10nError({
    code: 'L10N_E0042',
    details: { key, locale, path },
    level: 'error',
    next: 'Remove plural variations from the catalog; plural support is planned for a later milestone.',
    summary: 'Plural string catalog entries are not supported in v1',
  });
}

function buildPlatformShapeError(
  code: string,
  summary: string,
  path: string,
  details: Record<string, string | number | boolean | undefined> = {},
): L10nError {
  return new L10nError({
    code,
    details: { path, ...details },
    level: 'error',
    next: 'Regenerate the .xcstrings file from Xcode or fix the malformed entry.',
    summary,
  });
}

function assertCatalogShape(path: string, value: unknown): XCStringsCatalog {
  if (!isRecord(value)) {
    throw buildPlatformShapeError('L10N_E0031', 'String catalog is not a JSON object', path);
  }

  const sourceLanguage = value.sourceLanguage;
  const version = value.version;
  const strings = value.strings;

  if (typeof sourceLanguage !== 'string' || sourceLanguage.length === 0) {
    throw buildPlatformShapeError(
      'L10N_E0031',
      'String catalog is missing sourceLanguage',
      path,
    );
  }

  if (typeof version !== 'string' || version.length === 0) {
    throw buildPlatformShapeError('L10N_E0031', 'String catalog is missing version', path);
  }

  if (!isRecord(strings)) {
    throw buildPlatformShapeError('L10N_E0031', 'String catalog is missing strings', path);
  }

  return {
    sourceLanguage,
    strings: strings as Record<string, XCStringsEntry>,
    version,
  };
}

function getPlaceholderType(formatSpecifier: string | undefined, token: string): ICUPlaceholder['type'] {
  const normalizedSpecifier = (formatSpecifier ?? '').replace(/^%/, '').toLowerCase();
  const normalizedToken = token.replace(/^%(?:\d+\$)?/, '').toLowerCase();

  if (normalizedSpecifier === 'date') {
    return 'date';
  }

  if (
    normalizedSpecifier === 'd' ||
    normalizedSpecifier === 'ld' ||
    normalizedSpecifier === 'lld' ||
    normalizedSpecifier === 'f' ||
    normalizedToken === 'd' ||
    normalizedToken === 'ld' ||
    normalizedToken === 'lld' ||
    normalizedToken === 'f'
  ) {
    return 'number';
  }

  return 'string';
}

function toFormatSpecifier(type: ICUPlaceholder['type']): string {
  switch (type) {
    case 'number':
      return '%lld';
    case 'date':
      return 'date';
    case 'string':
      return '%@';
  }
}

function toStringToken(type: ICUPlaceholder['type'], argNum: number): string {
  switch (type) {
    case 'number':
      return `%${argNum}$lld`;
    case 'date':
    case 'string':
      return `%${argNum}$@`;
  }
}

async function loadCatalog(path: string): Promise<XCStringsCatalog> {
  let rawJson: unknown;

  try {
    rawJson = await readJsonFile(path);
  } catch {
    throw buildPlatformShapeError(
      'L10N_E0031',
      'String catalog could not be read or parsed',
      path,
    );
  }

  return assertCatalogShape(path, rawJson);
}

function hasUnsupportedVariations(
  localization: XCStringsLocalization | undefined,
  substitution: XCStringsSubstitution | undefined,
): boolean {
  return Boolean(
    localization?.variations?.device ||
      localization?.variations?.plural ||
      substitution?.variations?.device,
  );
}

function hasPluralVariation(
  localization: XCStringsLocalization | undefined,
  substitution: XCStringsSubstitution | undefined,
): boolean {
  return Boolean(localization?.variations?.plural || substitution?.variations?.plural);
}

function normalizeSubstitutions(
  substitutions: Record<string, XCStringsSubstitution> | undefined,
): Array<[string, XCStringsSubstitution]> {
  return Object.entries(substitutions ?? {}).sort(([leftName, left], [rightName, right]) => {
    const leftArg = left.argNum ?? Number.MAX_SAFE_INTEGER;
    const rightArg = right.argNum ?? Number.MAX_SAFE_INTEGER;

    return leftArg - rightArg || leftName.localeCompare(rightName);
  });
}

function fromLocalization(
  path: string,
  key: string,
  locale: string,
  localization: XCStringsLocalization,
): CanonicalKeyValue {
  if (localization.stringUnit && containsPluralSyntax(localization.stringUnit.value)) {
    throw buildUnsupportedPluralError(path, key, locale);
  }

  const substitutions = normalizeSubstitutions(localization.substitutions);
  for (const [, substitution] of substitutions) {
    if (hasPluralVariation(localization, substitution)) {
      throw buildUnsupportedPluralError(path, key, locale);
    }

    if (hasUnsupportedVariations(localization, substitution)) {
      throw buildPlatformShapeError(
        'L10N_E0032',
        'String catalog contains unsupported device or structured variations',
        path,
        { key, locale },
      );
    }
  }

  if (!localization.stringUnit) {
    throw buildPlatformShapeError(
      'L10N_E0032',
      'String catalog localization is missing stringUnit',
      path,
      { key, locale },
    );
  }

  const substitutionsByArgNum = new Map<number, { name: string; substitution: XCStringsSubstitution }>();
  const placeholderTypes = new Map<string, ICUPlaceholder['type']>();
  for (const [name, substitution] of substitutions) {
    if (!substitution.argNum || substitution.argNum < 1) {
      throw buildPlatformShapeError(
        'L10N_E0040',
        'String catalog substitution is missing argNum',
        path,
        { key, locale, placeholder: name },
      );
    }

    substitutionsByArgNum.set(substitution.argNum, { name, substitution });
  }

  let tokenIndex = 0;
  const seenPlaceholderNames = new Set<string>();
  const text = localization.stringUnit.value.replace(
    IOS_FORMAT_TOKEN_PATTERN,
    (token, structuredToken, pluralTokenName, positionalArgNum) => {
      if (pluralTokenName) {
        throw buildUnsupportedPluralError(path, key, locale);
      }

      tokenIndex += 1;

      const argNum = positionalArgNum ? Number(positionalArgNum) : tokenIndex;
      const mapped = substitutionsByArgNum.get(argNum);
      if (!mapped) {
        throw buildPlatformShapeError(
          'L10N_E0041',
          'String catalog placeholders do not align with substitutions metadata',
          path,
          { key, locale, token },
        );
      }

      if (!seenPlaceholderNames.has(mapped.name)) {
        placeholderTypes.set(
          mapped.name,
          getPlaceholderType(mapped.substitution.formatSpecifier, token),
        );
        seenPlaceholderNames.add(mapped.name);
      }

      return `{${mapped.name}}`;
    },
  );

  if (substitutions.length === 0 && tokenIndex > 0) {
    throw buildPlatformShapeError(
      'L10N_E0041',
      'String catalog contains format tokens without substitutions metadata',
      path,
      { key, locale },
    );
  }

  return {
    placeholders: extractUniqueIcuPlaceholders(text, placeholderTypes),
    text,
  };
}

function toLocalization(
  text: string,
  placeholders: ICUPlaceholder[],
): XCStringsLocalization {
  if (containsPluralSyntax(text)) {
    throw new L10nError({
      code: 'L10N_E0042',
      details: { text },
      level: 'error',
      next: 'Remove plural ICU syntax for now; plural support is planned for a later milestone.',
      summary: 'Plural ICU syntax is not supported in v1',
    });
  }

  const placeholdersByName = new Map(placeholders.map((placeholder) => [placeholder.name, placeholder]));
  const argNumsByName = new Map<string, number>();
  const substitutions: Record<string, XCStringsSubstitution> = {};
  let nextArgNum = 1;

  const value = text.replace(/\{([\w.-]+)\}/gu, (_match, rawName: string) => {
    const name = rawName;
    const placeholder = placeholdersByName.get(name) ?? { name, type: 'string' as const };
    let argNum = argNumsByName.get(name);

    if (!argNum) {
      argNum = nextArgNum;
      nextArgNum += 1;
      argNumsByName.set(name, argNum);
      substitutions[name] = {
        argNum,
        formatSpecifier: toFormatSpecifier(placeholder.type),
      };
    }

    return toStringToken(placeholder.type, argNum);
  });

  const localization: XCStringsLocalization = {
    stringUnit: {
      state: 'translated',
      value,
    },
  };

  if (Object.keys(substitutions).length > 0) {
    localization.substitutions = substitutions;
  }

  return localization;
}

function cloneCatalog(catalog: XCStringsCatalog): XCStringsCatalog {
  return {
    sourceLanguage: catalog.sourceLanguage,
    strings: structuredClone(catalog.strings),
    version: catalog.version,
  };
}

function createEmptyCatalog(sourceLanguage: string): XCStringsCatalog {
  return {
    sourceLanguage,
    strings: {},
    version: '1.0',
  };
}

async function catalogExists(path: string): Promise<boolean> {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

export class IosXcstringsAdapter implements Adapter {
  readonly platform = 'ios' as const;

  constructor(
    private readonly options: {
      keyTransform?: KeyTransform;
      sourceLocale: string;
    },
  ) {}

  fromPlatformPlaceholder(native: string): ICUPlaceholder {
    return {
      name: '',
      type: getPlaceholderType(native, native),
    };
  }

  async inspect(path: string): Promise<{
    keyCount: number;
    locales: string[];
    sourceLanguage: string;
    version: string;
  }> {
    const catalog = await loadCatalog(path);
    const locales = new Set<string>();

    for (const entry of Object.values(catalog.strings)) {
      for (const locale of Object.keys(entry.localizations ?? {})) {
        locales.add(locale);
      }
    }

    return {
      keyCount: Object.keys(catalog.strings).length,
      locales: [...locales].sort(),
      sourceLanguage: catalog.sourceLanguage,
      version: catalog.version,
    };
  }

  async read(path: string, locale?: string): Promise<CanonicalKeySet> {
    return this.readWithComments(path, locale);
  }

  async readWithComments(path: string, locale?: string): Promise<ExtendedCanonicalKeySet> {
    const catalog = await loadCatalog(path);
    const targetLocale = locale ?? catalog.sourceLanguage;
    const keys = new Map<string, CanonicalKeyValue>();

    for (const [platformKey, entry] of Object.entries(catalog.strings)) {
      const localization = entry.localizations?.[targetLocale];
      if (!localization) {
        continue;
      }

      const canonicalKey = this.reverseTransformKey(platformKey);
      const canonicalValue = fromLocalization(path, canonicalKey, targetLocale, localization);
      keys.set(
        canonicalKey,
        entry.comment
          ? {
              ...canonicalValue,
              comment: entry.comment,
            }
          : canonicalValue,
      );
    }

    return { keys };
  }

  reverseTransformKey(platformKey: string): string {
    const { toCanonical } = mapKeyTransform(this.options.keyTransform ?? 'identity');

    if (toCanonical === '.') {
      return platformKey;
    }

    return platformKey.replaceAll(toCanonical, '.');
  }

  toPlatformPlaceholder(icu: ICUPlaceholder): string {
    return toFormatSpecifier(icu.type);
  }

  transformKey(canonicalKey: string): string {
    const { fromCanonical } = mapKeyTransform(this.options.keyTransform ?? 'identity');

    if (fromCanonical === '.') {
      return canonicalKey;
    }

    return canonicalKey.replaceAll('.', fromCanonical);
  }

  async write(path: string, keys: CanonicalKeySet, locale: string): Promise<void> {
    const existingCatalog = (await catalogExists(path)) ? await loadCatalog(path) : null;
    const catalog = cloneCatalog(existingCatalog ?? createEmptyCatalog(this.options.sourceLocale));
    const nextKeys = new Set<string>();

    for (const [canonicalKey, keyValue] of keys.keys.entries()) {
      const platformKey = this.transformKey(canonicalKey);
      const keyValueWithComment = keyValue as CanonicalKeyValue;
      const placeholders =
        keyValue.placeholders.length > 0
          ? keyValue.placeholders
          : extractUniqueIcuPlaceholders(keyValue.text);

      const existingEntry = catalog.strings[platformKey] ?? {};
      const localization = toLocalization(keyValue.text, placeholders);
      nextKeys.add(platformKey);

      catalog.strings[platformKey] = {
        ...existingEntry,
        localizations: {
          ...(existingEntry.localizations ?? {}),
          [locale]: localization,
        },
      };

      if (typeof keyValueWithComment.comment === 'string' && keyValueWithComment.comment.length > 0) {
        catalog.strings[platformKey].comment = keyValueWithComment.comment;
      } else if ('comment' in keyValueWithComment) {
        if (keyValueWithComment.comment === '') {
          delete catalog.strings[platformKey].comment;
        } else {
          delete catalog.strings[platformKey].comment;
        }
      }
    }

    for (const [platformKey, entry] of Object.entries(catalog.strings)) {
      if (!nextKeys.has(platformKey)) {
        continue;
      }

      if (!entry.localizations || Object.keys(entry.localizations).length > 0) {
        continue;
      }

      delete catalog.strings[platformKey];
    }

    await writeJsonFileAtomic(path, catalog);
  }
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
