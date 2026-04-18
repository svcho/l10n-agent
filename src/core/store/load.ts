import { dirname, resolve } from 'node:path';

import { z } from 'zod';

import type { Config } from '../../config/schema.js';
import { loadConfig } from '../../config/load.js';
import { L10nError } from '../../errors/l10n-error.js';
import { readTextFile } from '../../utils/fs.js';
import { computeSourceHash } from './hash.js';
import {
  CacheFileSchema,
  HistoryEntrySchema,
  SourceFileSchema,
  TranslationFileSchema,
  type CacheFile,
  type HistoryEntry,
  type SourceFile,
  type TranslationFile,
} from './schemas.js';

export interface LoadedOptionalFile<T> {
  exists: boolean;
  path: string;
  value: T | null;
}

export interface LoadedTranslationFile extends LoadedOptionalFile<TranslationFile> {
  locale: string;
}

export interface ProjectSnapshot {
  cache: LoadedOptionalFile<CacheFile>;
  config: Config;
  configPath: string;
  history: LoadedOptionalFile<HistoryEntry[]>;
  l10nDir: string;
  platformPaths: Record<'ios' | 'android', string | null>;
  rootDir: string;
  source: {
    hashes: Map<string, string>;
    path: string;
    value: SourceFile;
  };
  translations: LoadedTranslationFile[];
}

async function loadJsonWithSchema<T>(
  path: string,
  schema: z.ZodType<T>,
  errorCode: string,
  summary: string,
): Promise<T> {
  let rawText: string;
  try {
    rawText = await readTextFile(path);
  } catch (error) {
    throw new L10nError({
      code: errorCode,
      details: { path },
      level: 'error',
      next: 'Create the missing file or fix its path.',
      summary,
    });
  }

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(rawText);
  } catch (error) {
    throw new L10nError({
      code: errorCode,
      details: { path },
      level: 'error',
      next: 'Fix the JSON syntax in the file.',
      summary,
    });
  }

  const parsedValue = schema.safeParse(parsedJson);
  if (!parsedValue.success) {
    const issue = parsedValue.error.issues[0];
    throw new L10nError({
      code: errorCode,
      details: {
        issue: issue?.message ?? 'unknown schema violation',
        path,
      },
      level: 'error',
      next: 'Fix the JSON shape so it matches the documented schema.',
      summary,
    });
  }

  return parsedValue.data;
}

async function loadOptionalJsonWithSchema<T>(
  path: string,
  schema: z.ZodType<T>,
  errorCode: string,
  summary: string,
): Promise<LoadedOptionalFile<T>> {
  try {
    const value = await loadJsonWithSchema(path, schema, errorCode, summary);
    return { exists: true, path, value };
  } catch (error) {
    if (error instanceof L10nError && error.diagnostic.details?.path === path) {
      try {
        await readTextFile(path);
      } catch {
        return { exists: false, path, value: null };
      }
    }

    throw error;
  }
}

function parseHistoryLines(rawText: string, path: string): HistoryEntry[] {
  if (rawText.trim().length === 0) {
    return [];
  }

  return rawText
    .trim()
    .split('\n')
    .map((line, index) => {
      let parsedLine: unknown;
      try {
        parsedLine = JSON.parse(line);
      } catch (error) {
        throw new L10nError({
          code: 'L10N_E0062',
          details: { line: index + 1, path },
          level: 'error',
          next: 'Fix the malformed JSONL entry in history.',
          summary: 'History log is not valid JSONL',
        });
      }

      const parsedEntry = HistoryEntrySchema.safeParse(parsedLine);
      if (!parsedEntry.success) {
        throw new L10nError({
          code: 'L10N_E0062',
          details: { line: index + 1, path },
          level: 'error',
          next: 'Fix the invalid history entry so it matches the schema.',
          summary: 'History log contains an invalid entry',
        });
      }

      return parsedEntry.data;
    });
}

async function loadOptionalHistory(path: string): Promise<LoadedOptionalFile<HistoryEntry[]>> {
  try {
    const rawText = await readTextFile(path);
    return {
      exists: true,
      path,
      value: parseHistoryLines(rawText, path),
    };
  } catch (error) {
    if (error instanceof L10nError) {
      throw error;
    }

    return {
      exists: false,
      path,
      value: null,
    };
  }
}

export async function loadProjectSnapshot(
  rootDir: string,
  explicitConfigPath?: string,
): Promise<ProjectSnapshot> {
  const { config, path: configPath } = await loadConfig(rootDir, explicitConfigPath);
  const l10nDir = dirname(configPath);
  const sourcePath = resolve(l10nDir, `source.${config.source_locale}.json`);
  const sourceValue = await loadJsonWithSchema(
    sourcePath,
    SourceFileSchema,
    'L10N_E0010',
    'Source file could not be loaded',
  );

  const hashes = new Map(
    Object.entries(sourceValue.keys).map(([key, value]) => [key, computeSourceHash(value)]),
  );

  const translations = await Promise.all(
    config.target_locales.map(async (locale) => {
      const translationPath = resolve(l10nDir, `translations.${locale}.json`);
      const loadedTranslation = await loadOptionalJsonWithSchema(
        translationPath,
        TranslationFileSchema,
        'L10N_E0011',
        'Translation file could not be loaded',
      );

      return {
        ...loadedTranslation,
        locale,
      };
    }),
  );

  const cache = await loadOptionalJsonWithSchema(
    resolve(l10nDir, '.cache.json'),
    CacheFileSchema,
    'L10N_E0060',
    'Cache file could not be loaded',
  );
  const history = await loadOptionalHistory(resolve(l10nDir, '.history.jsonl'));

  return {
    cache,
    config,
    configPath,
    history,
    l10nDir,
    platformPaths: {
      android: config.platforms.android ? resolve(rootDir, config.platforms.android.path) : null,
      ios: config.platforms.ios ? resolve(rootDir, config.platforms.ios.path) : null,
    },
    rootDir,
    source: {
      hashes,
      path: sourcePath,
      value: sourceValue,
    },
    translations,
  };
}
