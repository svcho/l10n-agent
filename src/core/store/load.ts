import { dirname, resolve } from 'node:path';

import { z } from 'zod';

import type { Config } from '../../config/schema.js';
import { loadConfig } from '../../config/load.js';
import { L10nError } from '../../errors/l10n-error.js';
import { readTextFile } from '../../utils/fs.js';
import type { Diagnostic } from '../diagnostics.js';
import { computeConfigHash, computeSourceFileHash, computeSourceHash } from './hash.js';
import {
  CacheFileSchema,
  HistoryEntrySchema,
  LegacyCacheFileSchema,
  LegacySyncStateFileSchema,
  SourceFileSchema,
  SyncStateFileSchema,
  TranslationFileSchema,
  type CacheFile,
  type HistoryEntry,
  type LegacyCacheFile,
  type LegacySyncStateFile,
  type SourceFile,
  type SyncStateFile,
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
  diagnostics: Diagnostic[];
  history: LoadedOptionalFile<HistoryEntry[]>;
  l10nDir: string;
  platformPaths: Record<'ios' | 'android', string | null>;
  rootDir: string;
  source: {
    hashes: Map<string, string>;
    path: string;
    value: SourceFile;
  };
  state: LoadedOptionalFile<SyncStateFile>;
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
  } catch {
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
  } catch {
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

function createHistoryTrailingLineWarning(path: string, line: number): Diagnostic {
  return {
    code: 'L10N_E0078',
    details: { line, path },
    level: 'warn',
    next: 'Inspect the trailing history entry. The command ignored it so the rest of history remains usable.',
    summary: 'History log has a trailing corrupt line that was ignored',
  };
}

function migrateLegacyCacheFile(cache: LegacyCacheFile): CacheFile {
  return {
    entries: Object.entries(cache.entries)
      .flatMap(([cacheKey, entry]) => {
        const [sourceHash, locale, ...modelVersionParts] = cacheKey.split('|');
        const modelVersion = modelVersionParts.join('|');

        if (!sourceHash || !locale || modelVersion.length === 0) {
          return [];
        }

        return [
          {
            cached_at: entry.cached_at,
            locale,
            model_version: modelVersion,
            source_hash: sourceHash,
            text: entry.text,
          },
        ];
      })
      .sort((left, right) =>
        left.source_hash.localeCompare(right.source_hash) ||
        left.locale.localeCompare(right.locale) ||
        left.model_version.localeCompare(right.model_version) ||
        left.cached_at.localeCompare(right.cached_at),
      ),
    version: 2,
  };
}

function parseHistoryLines(
  rawText: string,
  path: string,
): {
  diagnostics: Diagnostic[];
  entries: HistoryEntry[];
} {
  if (rawText.trim().length === 0) {
    return {
      diagnostics: [],
      entries: [],
    };
  }

  const diagnostics: Diagnostic[] = [];
  const entries: HistoryEntry[] = [];
  const lines = rawText.split('\n');
  while (lines.length > 0 && lines[lines.length - 1] === '') {
    lines.pop();
  }

  for (const [index, line] of lines.entries()) {
    const lineNumber = index + 1;
    const isLastLine = index === lines.length - 1;

    if (line.trim().length === 0) {
      if (isLastLine) {
        continue;
      }

      throw new L10nError({
        code: 'L10N_E0062',
        details: { line: lineNumber, path },
        level: 'error',
        next: 'Fix the malformed JSONL entry in history.',
        summary: 'History log is not valid JSONL',
      });
    }

    let parsedLine: unknown;
    try {
      parsedLine = JSON.parse(line);
    } catch {
      if (isLastLine) {
        diagnostics.push(createHistoryTrailingLineWarning(path, lineNumber));
        continue;
      }

      throw new L10nError({
        code: 'L10N_E0062',
        details: { line: lineNumber, path },
        level: 'error',
        next: 'Fix the malformed JSONL entry in history.',
        summary: 'History log is not valid JSONL',
      });
    }

    const parsedEntry = HistoryEntrySchema.safeParse(parsedLine);
    if (!parsedEntry.success) {
      if (isLastLine) {
        diagnostics.push(createHistoryTrailingLineWarning(path, lineNumber));
        continue;
      }

      throw new L10nError({
        code: 'L10N_E0062',
        details: { line: lineNumber, path },
        level: 'error',
        next: 'Fix the invalid history entry so it matches the schema.',
        summary: 'History log contains an invalid entry',
      });
    }

    entries.push(parsedEntry.data);
  }

  return { diagnostics, entries };
}

async function loadOptionalCache(path: string): Promise<LoadedOptionalFile<CacheFile>> {
  try {
    const rawText = await readTextFile(path);

    let parsedJson: unknown;
    try {
      parsedJson = JSON.parse(rawText);
    } catch {
      throw new L10nError({
        code: 'L10N_E0060',
        details: { path },
        level: 'error',
        next: 'Fix the JSON syntax in the file.',
        summary: 'Cache file could not be loaded',
      });
    }

    const currentCache = CacheFileSchema.safeParse(parsedJson);
    if (currentCache.success) {
      return {
        exists: true,
        path,
        value: currentCache.data,
      };
    }

    const legacyCache = LegacyCacheFileSchema.safeParse(parsedJson);
    if (legacyCache.success) {
      return {
        exists: true,
        path,
        value: migrateLegacyCacheFile(legacyCache.data),
      };
    }

    const issue = currentCache.error.issues[0] ?? legacyCache.error.issues[0];
    throw new L10nError({
      code: 'L10N_E0060',
      details: {
        issue: issue?.message ?? 'unknown schema violation',
        path,
      },
      level: 'error',
      next: 'Fix the JSON shape so it matches the documented schema.',
      summary: 'Cache file could not be loaded',
    });
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

async function loadOptionalHistory(
  path: string,
): Promise<{ diagnostics: Diagnostic[]; history: LoadedOptionalFile<HistoryEntry[]> }> {
  try {
    const rawText = await readTextFile(path);
    const parsed = parseHistoryLines(rawText, path);
    return {
      diagnostics: parsed.diagnostics,
      history: {
        exists: true,
        path,
        value: parsed.entries,
      },
    };
  } catch (error) {
    if (error instanceof L10nError) {
      throw error;
    }

    return {
      diagnostics: [],
      history: {
        exists: false,
        path,
        value: null,
      },
    };
  }
}

async function loadOptionalSyncState(
  path: string,
  configHash: string,
  sourceHash: string,
): Promise<{ diagnostics: Diagnostic[]; state: LoadedOptionalFile<SyncStateFile> }> {
  try {
    const rawText = await readTextFile(path);

    let parsedJson: unknown;
    try {
      parsedJson = JSON.parse(rawText);
    } catch {
      throw new L10nError({
        code: 'L10N_E0069',
        details: { path },
        level: 'error',
        next: 'Fix the JSON syntax in the file.',
        summary: 'Sync state file could not be loaded',
      });
    }

    const currentState = SyncStateFileSchema.safeParse(parsedJson);
    let parsedState: SyncStateFile | LegacySyncStateFile | null = null;
    if (currentState.success) {
      parsedState = currentState.data;
    } else {
      const legacyState = LegacySyncStateFileSchema.safeParse(parsedJson);
      if (legacyState.success) {
        parsedState = legacyState.data;
      } else {
        const issue = currentState.error.issues[0] ?? legacyState.error.issues[0];
        throw new L10nError({
          code: 'L10N_E0069',
          details: {
            issue: issue?.message ?? 'unknown schema violation',
            path,
          },
          level: 'error',
          next: 'Fix the JSON shape so it matches the documented schema.',
          summary: 'Sync state file could not be loaded',
        });
      }
    }

    if (
      !('config_hash' in parsedState) ||
      !('source_hash' in parsedState) ||
      parsedState.config_hash !== configHash ||
      parsedState.source_hash !== sourceHash
    ) {
      return {
        diagnostics: [
          {
            code: 'L10N_E0080',
            details: { path },
            level: 'warn',
            next: 'A fresh sync plan will be used because the saved resume state no longer matches the current source or config.',
            summary: 'Saved sync resume state was discarded because it is stale',
          },
        ],
        state: {
          exists: false,
          path,
          value: null,
        },
      };
    }

    return {
      diagnostics: [],
      state: {
        exists: true,
        path,
        value: parsedState,
      },
    };
  } catch (error) {
    if (error instanceof L10nError) {
      throw error;
    }

    return {
      diagnostics: [],
      state: {
        exists: false,
        path,
        value: null,
      },
    };
  }
}

export async function loadProjectSnapshot(
  rootDir: string,
  explicitConfigPath?: string,
): Promise<ProjectSnapshot> {
  const { config, path: configPath } = await loadConfig(rootDir, explicitConfigPath);
  const diagnostics: Diagnostic[] = [];
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
  const configHash = computeConfigHash(config);
  const sourceFileHash = computeSourceFileHash(sourceValue);

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

  const cache = await loadOptionalCache(resolve(l10nDir, '.cache.json'));
  const history = await loadOptionalHistory(resolve(l10nDir, '.history.jsonl'));
  diagnostics.push(...history.diagnostics);
  const state = await loadOptionalSyncState(resolve(l10nDir, '.state.json'), configHash, sourceFileHash);
  diagnostics.push(...state.diagnostics);

  return {
    cache,
    config,
    configPath,
    diagnostics,
    history: history.history,
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
    state: state.state,
    translations,
  };
}
