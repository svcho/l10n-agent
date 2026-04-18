import { access, constants, readdir, rm } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';

import type { KeyTransform } from '../../config/schema.js';
import { containsPluralSyntax, extractUniqueIcuPlaceholders } from '../../core/placeholders/icu.js';
import type { ICUPlaceholder } from '../../core/placeholders/types.js';
import { L10nError } from '../../errors/l10n-error.js';
import { readTextFile, writeTextFileAtomic } from '../../utils/fs.js';
import type { Adapter, CanonicalKeySet } from '../base.js';
import type { CanonicalKeyValue, ExtendedCanonicalKeySet } from '../canonical.js';

const XML_DECLARATION = '<?xml version="1.0" encoding="utf-8"?>';
const ANDROID_FORMAT_TOKEN_PATTERN = /%(?:(\d+)\$)?([sdf])/gu;
const ANDROID_META_PREFIX = 'l10n-agent-meta ';

interface AndroidEntry {
  key: string;
  metadata: {
    placeholders: ICUPlaceholder[];
  } | null;
  text: string;
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
    next: 'Fix the malformed strings.xml resource file or regenerate it from the canonical store.',
    summary,
  });
}

function buildUnsupportedPluralError(path: string, key: string, locale: string): L10nError {
  return new L10nError({
    code: 'L10N_E0042',
    details: { key, locale, path },
    level: 'error',
    next: 'Remove plural resources from strings.xml; plural support is planned for a later milestone.',
    summary: 'Android plural resources are not supported in v1',
  });
}

function localeToAndroidDirectory(locale: string): string {
  const [language, region] = locale.split('-');
  if (!language) {
    return 'values';
  }

  if (!region) {
    return `values-${language}`;
  }

  return `values-${language}-r${region}`;
}

function androidDirectoryToLocale(directory: string): string | null {
  if (directory === 'values') {
    return null;
  }

  const match = /^values-([a-z]{2})(?:-r([A-Z]{2}))?$/.exec(directory);
  if (!match) {
    return null;
  }

  const [, language, region] = match;
  if (!language) {
    return null;
  }

  return region ? `${language}-${region}` : language;
}

export function resolveAndroidLocalePath(basePath: string, sourceLocale: string, locale: string): string {
  if (locale === sourceLocale) {
    return basePath;
  }

  const valuesDir = dirname(basePath);
  const resDir = dirname(valuesDir);
  return join(resDir, localeToAndroidDirectory(locale), basename(basePath));
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

function decodeXmlEntities(text: string): string {
  return text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
}

function decodeAndroidEscapes(text: string): string {
  let result = '';

  for (let index = 0; index < text.length; index += 1) {
    const current = text[index];
    if (current !== '\\') {
      result += current;
      continue;
    }

    const next = text[index + 1];
    if (next === undefined) {
      result += '\\';
      continue;
    }

    switch (next) {
      case 'n':
        result += '\n';
        break;
      case 't':
        result += '\t';
        break;
      case '"':
      case "'":
      case '@':
      case '?':
      case '\\':
        result += next;
        break;
      default:
        result += next;
        break;
    }

    index += 1;
  }

  return result;
}

function decodePlatformText(text: string): string {
  return decodeAndroidEscapes(decodeXmlEntities(text));
}

function encodeAndroidEscapes(text: string): string {
  let result = '';

  for (let index = 0; index < text.length; index += 1) {
    const current = text[index];

    if (current === '%') {
      const remainder = text.slice(index);
      if (!/^%(?:(\d+)\$)?[sdf]/u.test(remainder)) {
        result += '%%';
        continue;
      }
    }

    switch (current) {
      case '&':
        result += '&amp;';
        break;
      case '<':
        result += '&lt;';
        break;
      case '>':
        result += '&gt;';
        break;
      case '\n':
        result += '\\n';
        break;
      case '\t':
        result += '\\t';
        break;
      case '"':
        result += '\\"';
        break;
      case "'":
        result += "\\'";
        break;
      case '@':
      case '?':
        if (index === 0) {
          result += `\\${current}`;
        } else {
          result += current;
        }
        break;
      case '\\':
        result += '\\\\';
        break;
      default:
        result += current;
        break;
    }
  }

  return result;
}

function parseAttributes(path: string, key: string, rawAttributes: string): Map<string, string> {
  const attributes = new Map<string, string>();
  const attributePattern = /([\w:.-]+)\s*=\s*"([^"]*)"/gu;

  for (const match of rawAttributes.matchAll(attributePattern)) {
    const [, name, value] = match;
    if (!name) {
      continue;
    }

    attributes.set(name, decodeXmlEntities(value ?? ''));
  }

  const remainder = rawAttributes.replace(attributePattern, '').trim();
  if (remainder.length > 0) {
    throw buildPlatformShapeError('L10N_E0032', 'String resource attributes could not be parsed', path, {
      key,
    });
  }

  return attributes;
}

function sanitizeXmlComment(comment: string): string {
  return comment.replaceAll('--', '- -');
}

function getPlaceholderType(specifier: string): ICUPlaceholder['type'] {
  switch (specifier.toLowerCase()) {
    case 'd':
    case 'f':
      return 'number';
    case 's':
    default:
      return 'string';
  }
}

function toFormatToken(type: ICUPlaceholder['type'], argNum: number): string {
  switch (type) {
    case 'number':
      return `%${argNum}$d`;
    case 'date':
    case 'string':
      return `%${argNum}$s`;
  }
}

function parseMetadataComment(comment: string, path: string): { placeholders: ICUPlaceholder[] } | null {
  const trimmed = comment.trim();
  if (!trimmed.startsWith(ANDROID_META_PREFIX)) {
    return null;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed.slice(ANDROID_META_PREFIX.length));
  } catch {
    throw buildPlatformShapeError('L10N_E0032', 'Android metadata comment is not valid JSON', path);
  }

  if (
    !parsed ||
    typeof parsed !== 'object' ||
    Array.isArray(parsed) ||
    !('placeholders' in parsed) ||
    !Array.isArray(parsed.placeholders)
  ) {
    throw buildPlatformShapeError('L10N_E0032', 'Android metadata comment has an invalid shape', path);
  }

  const placeholders = parsed.placeholders.map((value) => {
    if (
      !value ||
      typeof value !== 'object' ||
      Array.isArray(value) ||
      typeof value.name !== 'string' ||
      (value.type !== 'string' && value.type !== 'number' && value.type !== 'date')
    ) {
      throw buildPlatformShapeError('L10N_E0032', 'Android metadata comment has an invalid placeholder', path);
    }

    return {
      name: value.name,
      type: value.type,
    } satisfies ICUPlaceholder;
  });

  return { placeholders };
}

function fromPlatformText(
  path: string,
  key: string,
  locale: string,
  text: string,
  metadata: { placeholders: ICUPlaceholder[] } | null,
): CanonicalKeyValue {
  const decodedText = decodePlatformText(text);
  const placeholdersByPosition = new Map<number, ICUPlaceholder>();
  for (const [index, placeholder] of (metadata?.placeholders ?? []).entries()) {
    placeholdersByPosition.set(index + 1, placeholder);
  }

  let sequentialIndex = 0;
  const usedPlaceholderNames = new Set<string>();
  const placeholderTypes = new Map<string, ICUPlaceholder['type']>();
  const canonicalText = decodedText
    .replaceAll('%%', '%')
    .replace(
    ANDROID_FORMAT_TOKEN_PATTERN,
    (_match, positionalIndex: string | undefined, specifier: string) => {
      const argNum = positionalIndex ? Number(positionalIndex) : sequentialIndex + 1;
      sequentialIndex = Math.max(sequentialIndex + 1, argNum);
      const metadataPlaceholder = placeholdersByPosition.get(argNum);
      const placeholder =
        metadataPlaceholder ??
        ({
          name: `arg${argNum}`,
          type: getPlaceholderType(specifier),
        } satisfies ICUPlaceholder);

      usedPlaceholderNames.add(placeholder.name);
      placeholderTypes.set(placeholder.name, metadataPlaceholder?.type ?? getPlaceholderType(specifier));
      return `{${placeholder.name}}`;
    },
  );

  if ((metadata?.placeholders.length ?? 0) > 0 && usedPlaceholderNames.size !== metadata?.placeholders.length) {
    throw buildPlatformShapeError(
      'L10N_E0041',
      'Android format placeholders do not align with l10n-agent metadata',
      path,
      { key, locale },
    );
  }

  if (containsPluralSyntax(canonicalText)) {
    throw buildUnsupportedPluralError(path, key, locale);
  }

  return {
    placeholders: extractUniqueIcuPlaceholders(canonicalText, placeholderTypes),
    text: canonicalText,
  };
}

function toPlatformText(text: string, placeholders: ICUPlaceholder[]): { metadataComment: string | null; text: string } {
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
  const orderedPlaceholders: ICUPlaceholder[] = [];
  let nextArgNum = 1;

  const formattedText = text.replace(/\{([\w.-]+)\}/gu, (_match, rawName: string) => {
    const name = rawName;
    const placeholder = placeholdersByName.get(name) ?? { name, type: 'string' as const };
    let argNum = argNumsByName.get(name);

    if (!argNum) {
      argNum = nextArgNum;
      nextArgNum += 1;
      argNumsByName.set(name, argNum);
      orderedPlaceholders.push(placeholder);
    }

    return toFormatToken(placeholder.type, argNum);
  });

  return {
    metadataComment:
      orderedPlaceholders.length > 0
        ? `${ANDROID_META_PREFIX}${JSON.stringify({ placeholders: orderedPlaceholders })}`
        : null,
    text: encodeAndroidEscapes(formattedText),
  };
}

function parseEntries(path: string, xml: string): AndroidEntry[] {
  const rootMatch = /^\s*(?:<\?xml[^>]*\?>\s*)?<resources(?:\s[^>]*)?>([\s\S]*)<\/resources>\s*$/u.exec(xml);
  if (!rootMatch) {
    throw buildPlatformShapeError('L10N_E0031', 'strings.xml is missing a <resources> root element', path);
  }

  const inner = rootMatch[1] ?? '';
  const tokenPattern =
    /<!--([\s\S]*?)-->|<string\b([^>]*)>([\s\S]*?)<\/string>|<(plurals|string-array)\b[\s\S]*?<\/\4>|<[^>]+>|([^<]+)/gu;
  const entries: AndroidEntry[] = [];
  let pendingMetadata: { placeholders: ICUPlaceholder[] } | null = null;
  let lastIndex = 0;

  for (const match of inner.matchAll(tokenPattern)) {
    const fullMatch = match[0];
    const matchIndex = match.index ?? 0;

    if (matchIndex !== lastIndex) {
      throw buildPlatformShapeError('L10N_E0031', 'strings.xml contains malformed XML content', path);
    }
    lastIndex = matchIndex + fullMatch.length;

    const [comment, rawAttributes, rawText, unsupportedTag, rawTextNode] = match.slice(1);
    if (typeof comment === 'string') {
      pendingMetadata = parseMetadataComment(comment, path) ?? pendingMetadata;
      continue;
    }

    if (typeof rawTextNode === 'string') {
      if (rawTextNode.trim().length > 0) {
        throw buildPlatformShapeError('L10N_E0032', 'strings.xml contains unexpected text nodes', path);
      }
      continue;
    }

    if (typeof unsupportedTag === 'string') {
      if (unsupportedTag === 'plurals') {
        throw buildUnsupportedPluralError(path, '<unknown>', '<unknown>');
      }

      throw buildPlatformShapeError('L10N_E0032', 'strings.xml contains an unsupported resource type', path, {
        tag: unsupportedTag,
      });
    }

    if (typeof rawAttributes !== 'string' || typeof rawText !== 'string') {
      throw buildPlatformShapeError('L10N_E0031', 'strings.xml contains malformed resource entries', path);
    }

    const attributes = parseAttributes(path, '<unknown>', rawAttributes);
    const key = attributes.get('name');
    if (!key) {
      throw buildPlatformShapeError('L10N_E0032', 'String resource is missing a name attribute', path);
    }

    if (attributes.has('translatable') && attributes.get('translatable') === 'false') {
      pendingMetadata = null;
      continue;
    }

    entries.push({
      key,
      metadata: pendingMetadata,
      text: rawText,
    });
    pendingMetadata = null;
  }

  if (lastIndex !== inner.length) {
    throw buildPlatformShapeError('L10N_E0031', 'strings.xml contains malformed trailing content', path);
  }

  return entries;
}

function renderResources(entries: Array<{ key: string; metadataComment: string | null; text: string }>): string {
  const lines = [XML_DECLARATION, '<resources>'];

  for (const entry of entries) {
    if (entry.metadataComment) {
      lines.push(`  <!-- ${sanitizeXmlComment(entry.metadataComment)} -->`);
    }

    lines.push(`  <string name="${entry.key}">${entry.text}</string>`);
  }

  lines.push('</resources>');
  lines.push('');
  return lines.join('\n');
}

export class AndroidStringsAdapter implements Adapter {
  readonly platform = 'android' as const;

  constructor(
    private readonly options: {
      keyTransform?: KeyTransform;
      sourceLocale: string;
    },
  ) {}

  fromPlatformPlaceholder(native: string): ICUPlaceholder {
    const match = /%(?:(\d+)\$)?([sdf])/u.exec(native);
    return {
      name: '',
      type: getPlaceholderType(match?.[2] ?? 's'),
    };
  }

  async inspect(path: string): Promise<{
    keyCount: number;
    locales: string[];
  }> {
    const sourceFilePath = resolveAndroidLocalePath(path, this.options.sourceLocale, this.options.sourceLocale);
    const sourceKeys = await this.read(sourceFilePath, this.options.sourceLocale);
    const resDir = dirname(dirname(path));
    const baseName = basename(path);
    const locales = new Set<string>();

    try {
      const directories = await readdir(resDir, { withFileTypes: true });
      for (const entry of directories) {
        if (!entry.isDirectory()) {
          continue;
        }

        const locale = androidDirectoryToLocale(entry.name);
        if (entry.name !== 'values' && !locale) {
          continue;
        }

        const candidatePath = join(resDir, entry.name, baseName);
        if (!(await fileExists(candidatePath))) {
          continue;
        }

        locales.add(locale ?? this.options.sourceLocale);
      }
    } catch {
      locales.add(this.options.sourceLocale);
    }

    return {
      keyCount: sourceKeys.keys.size,
      locales: [...locales].sort(),
    };
  }

  async read(path: string, locale?: string): Promise<CanonicalKeySet> {
    return this.readWithComments(path, locale);
  }

  async readWithComments(path: string, locale?: string): Promise<ExtendedCanonicalKeySet> {
    const targetLocale = locale ?? this.options.sourceLocale;
    const targetPath = resolveAndroidLocalePath(path, this.options.sourceLocale, targetLocale);

    if (!(await fileExists(targetPath))) {
      return { keys: new Map() };
    }

    let rawXml: string;
    try {
      rawXml = await readTextFile(targetPath);
    } catch {
      throw buildPlatformShapeError('L10N_E0031', 'strings.xml could not be read', targetPath);
    }

    const keys = new Map<string, CanonicalKeyValue>();
    for (const entry of parseEntries(targetPath, rawXml)) {
      const canonicalKey = this.reverseTransformKey(entry.key);
      keys.set(canonicalKey, fromPlatformText(targetPath, canonicalKey, targetLocale, entry.text, entry.metadata));
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
    return toFormatToken(icu.type, 1);
  }

  transformKey(canonicalKey: string): string {
    const { fromCanonical } = mapKeyTransform(this.options.keyTransform ?? 'identity');
    if (fromCanonical === '.') {
      return canonicalKey;
    }

    return canonicalKey.replaceAll('.', fromCanonical);
  }

  async write(path: string, keys: CanonicalKeySet, locale: string): Promise<void> {
    const targetPath = resolveAndroidLocalePath(path, this.options.sourceLocale, locale);
    if (locale !== this.options.sourceLocale && keys.keys.size === 0) {
      try {
        await rm(targetPath);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
          throw error;
        }
      }
      return;
    }
    const renderedEntries = [...keys.keys.entries()]
      .sort(([leftKey], [rightKey]) => leftKey.localeCompare(rightKey))
      .map(([canonicalKey, keyValue]) => {
        const placeholders =
          keyValue.placeholders.length > 0 ? keyValue.placeholders : extractUniqueIcuPlaceholders(keyValue.text);
        const rendered = toPlatformText(keyValue.text, placeholders);

        return {
          key: this.transformKey(canonicalKey),
          metadataComment: rendered.metadataComment,
          text: rendered.text,
        };
      });

    const xml = renderResources(renderedEntries);
    await writeTextFileAtomic(targetPath, xml);
  }
}
