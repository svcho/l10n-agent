import { access, constants, mkdir, readdir, rm } from 'node:fs/promises';
import { basename, dirname, resolve } from 'node:path';

import type { KeyTransform } from '../../config/schema.js';
import { L10nError } from '../../errors/l10n-error.js';
import { extractUniqueIcuPlaceholders } from '../../core/placeholders/icu.js';
import type { ICUPlaceholder } from '../../core/placeholders/types.js';
import { readTextFile, writeTextFileAtomic } from '../../utils/fs.js';
import type { Adapter, CanonicalKeySet } from '../base.js';
import type { ExtendedCanonicalKeySet } from '../canonical.js';

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

function buildPlatformShapeError(
  summary: string,
  path: string,
  details: Record<string, string | number | boolean | undefined> = {},
): L10nError {
  return new L10nError({
    code: 'L10N_E0031',
    details: { path, ...details },
    level: 'error',
    next: 'Fix the malformed Localizable.strings file or regenerate it from the canonical store.',
    summary,
  });
}

function skipTrivia(text: string, startIndex: number): number {
  let index = startIndex;
  while (index < text.length) {
    const current = text[index] ?? '';
    const next = text[index + 1] ?? '';

    if (/\s/u.test(current)) {
      index += 1;
      continue;
    }

    if (current === '/' && next === '/') {
      const newlineIndex = text.indexOf('\n', index + 2);
      if (newlineIndex === -1) {
        return text.length;
      }
      index = newlineIndex + 1;
      continue;
    }

    if (current === '/' && next === '*') {
      const closingIndex = text.indexOf('*/', index + 2);
      if (closingIndex === -1) {
        return text.length;
      }
      index = closingIndex + 2;
      continue;
    }

    return index;
  }

  return index;
}

function readQuotedToken(path: string, text: string, startIndex: number): { nextIndex: number; value: string } {
  if (text[startIndex] !== '"') {
    throw buildPlatformShapeError('Localizable.strings contains malformed content', path);
  }

  let index = startIndex + 1;
  let raw = '';

  while (index < text.length) {
    const current = text[index] ?? '';
    if (current === '\\') {
      const escaped = text[index + 1];
      if (escaped === undefined) {
        throw buildPlatformShapeError('Localizable.strings contains malformed content', path);
      }
      raw += `\\${escaped}`;
      index += 2;
      continue;
    }

    if (current === '"') {
      try {
        return {
          nextIndex: index + 1,
          value: JSON.parse(`"${raw}"`) as string,
        };
      } catch {
        throw buildPlatformShapeError('Localizable.strings contains malformed content', path);
      }
    }

    raw += current;
    index += 1;
  }

  throw buildPlatformShapeError('Localizable.strings contains malformed content', path);
}

function parseStringsFile(path: string, text: string): Map<string, string> {
  const entries = new Map<string, string>();
  let index = 0;

  while (true) {
    index = skipTrivia(text, index);
    if (index >= text.length) {
      break;
    }

    try {
      const keyToken = readQuotedToken(path, text, index);
      index = skipTrivia(text, keyToken.nextIndex);
      if (text[index] !== '=') {
        throw buildPlatformShapeError('Localizable.strings contains malformed content', path);
      }

      index = skipTrivia(text, index + 1);
      const valueToken = readQuotedToken(path, text, index);
      index = skipTrivia(text, valueToken.nextIndex);
      if (text[index] !== ';') {
        throw buildPlatformShapeError('Localizable.strings contains malformed content', path);
      }

      entries.set(keyToken.value, valueToken.value);
      index += 1;
    } catch (error) {
      if (error instanceof L10nError) {
        throw error;
      }

      throw buildPlatformShapeError('Localizable.strings contains malformed content', path);
    }
  }

  return entries;
}

function escapeQuotedValue(value: string): string {
  return JSON.stringify(value).slice(1, -1);
}

export function resolveIosStringsLocalePath(path: string, sourceLocale: string, locale: string): string {
  const fileName = basename(path);
  const containingDir = dirname(path);
  const containingDirName = basename(containingDir);

  if (containingDirName.endsWith('.lproj')) {
    return resolve(dirname(containingDir), `${locale}.lproj`, fileName);
  }

  if (locale === sourceLocale) {
    return path;
  }

  return resolve(containingDir, `${locale}.lproj`, fileName);
}

function getPlaceholderType(token: string): ICUPlaceholder['type'] {
  const normalizedToken = token.replace(/^%(?:\d+\$)?/, '').toLowerCase();
  return normalizedToken === 'd' || normalizedToken === 'ld' || normalizedToken === 'lld' || normalizedToken === 'f'
    ? 'number'
    : 'string';
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

export class IosStringsAdapter implements Adapter {
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
      type: getPlaceholderType(native),
    };
  }

  async inspect(path: string): Promise<{
    keyCount: number;
    locales: string[];
    sourceLanguage: string;
    version: string | null;
  }> {
    const sourceEntries = await this.read(path, this.options.sourceLocale);
    const localeContainer = dirname(path);
    const localeRoot = basename(localeContainer).endsWith('.lproj') ? dirname(localeContainer) : localeContainer;
    const localeDirs = await readdir(localeRoot, { withFileTypes: true });
    const locales = localeDirs
      .filter((entry) => entry.isDirectory() && entry.name.endsWith('.lproj'))
      .map((entry) => entry.name.slice(0, -'.lproj'.length))
      .sort();

    return {
      keyCount: sourceEntries.keys.size,
      locales,
      sourceLanguage: this.options.sourceLocale,
      version: null,
    };
  }

  async read(path: string, locale = this.options.sourceLocale): Promise<CanonicalKeySet> {
    return this.readWithComments(path, locale);
  }

  async readWithComments(path: string, locale = this.options.sourceLocale): Promise<ExtendedCanonicalKeySet> {
    const localePath = resolveIosStringsLocalePath(path, this.options.sourceLocale, locale);
    if (!(await pathExists(localePath))) {
      return { keys: new Map() };
    }

    const content = await readTextFile(localePath).catch(() => {
      throw buildPlatformShapeError('Localizable.strings could not be read', localePath);
    });
    const entries = parseStringsFile(localePath, content);
    const keys = new Map<
      string,
      {
        placeholders: ICUPlaceholder[];
        text: string;
      }
    >();

    for (const [platformKey, textValue] of entries.entries()) {
      const canonicalKey = this.reverseTransformKey(platformKey);
      keys.set(canonicalKey, {
        placeholders: extractUniqueIcuPlaceholders(textValue),
        text: textValue,
      });
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
    switch (icu.type) {
      case 'number':
        return '%lld';
      case 'date':
      case 'string':
        return '%@';
    }
  }

  transformKey(canonicalKey: string): string {
    const { fromCanonical } = mapKeyTransform(this.options.keyTransform ?? 'identity');
    if (fromCanonical === '.') {
      return canonicalKey;
    }
    return canonicalKey.replaceAll('.', fromCanonical);
  }

  async write(path: string, keys: CanonicalKeySet, locale: string): Promise<void> {
    const localePath = resolveIosStringsLocalePath(path, this.options.sourceLocale, locale);
    if (keys.keys.size === 0) {
      await rm(localePath, { force: true });
      return;
    }

    await mkdir(dirname(localePath), { recursive: true });

    const lines = [...keys.keys.entries()]
      .map(([canonicalKey, value]) => [this.transformKey(canonicalKey), value.text] as const)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([platformKey, textValue]) => `"${escapeQuotedValue(platformKey)}" = "${escapeQuotedValue(textValue)}";`);

    await writeTextFileAtomic(localePath, `${lines.join('\n')}\n`);
  }
}

export function isIosStringsPath(path: string): boolean {
  return path.toLowerCase().endsWith('.strings');
}
