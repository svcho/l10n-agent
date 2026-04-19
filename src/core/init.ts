import { access, constants, readdir } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';

import YAML from 'yaml';

import type { Config } from '../config/schema.js';
import { codexPreflight, type CodexPreflightResult } from '../providers/codex-local.js';
import { writeTextFileAtomic } from '../utils/fs.js';
import { L10nError } from '../errors/l10n-error.js';
import { loadProjectSnapshot } from './store/load.js';
import { appendHistoryEntries, createTranslationFile } from './store/write.js';
import { buildHistoryId, createInitHistoryEntry } from './history.js';
import { snapshotManagedFiles } from './project-files.js';
import { runImport, type ImportSource } from './import.js';

interface DetectedPlatformPaths {
  android: string | null;
  ios: string | null;
}

export interface InitReport {
  imported_from: ImportSource | null;
  ok: boolean;
  preflight: CodexPreflightResult;
  summary: {
    config_path: string;
    source_locale: string;
    target_locales: string[];
  };
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function findFirstMatch(
  rootDir: string,
  predicate: (relativePath: string) => boolean,
): Promise<string | null> {
  const ignored = new Set(['.git', 'dist', 'node_modules']);

  async function visit(currentDir: string): Promise<string | null> {
    const entries = await readdir(currentDir, { withFileTypes: true });

    for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
      const absolutePath = resolve(currentDir, entry.name);
      const relativePath = relative(rootDir, absolutePath);

      if (entry.isDirectory()) {
        if (ignored.has(entry.name)) {
          continue;
        }

        const nested = await visit(absolutePath);
        if (nested) {
          return nested;
        }
        continue;
      }

      if (predicate(relativePath)) {
        return relativePath;
      }
    }

    return null;
  }

  return visit(rootDir);
}

async function detectPlatformPaths(rootDir: string): Promise<DetectedPlatformPaths> {
  const [iosCatalog, iosStrings, android] = await Promise.all([
    findFirstMatch(rootDir, (path) => path.endsWith('.xcstrings')),
    findFirstMatch(rootDir, (path) => /(?:^|\/)[^/]+\.lproj\/Localizable\.strings$/u.test(path)),
    findFirstMatch(rootDir, (path) => /(?:^|\/)res\/values\/strings\.xml$/u.test(path)),
  ]);

  return {
    android,
    ios: iosCatalog ?? iosStrings,
  };
}

function buildConfig(options: {
  androidPath: string | null;
  iosPath: string | null;
  providerModel?: string;
  sourceLocale: string;
  targetLocales: string[];
}): Config {
  return {
    keys: {
      case: 'dotted.lower',
      forbidden_prefixes: [],
      max_depth: 4,
      scopes: [],
    },
    platforms: {
      ...(options.androidPath
        ? {
            android: {
              enabled: true,
              key_transform: 'snake_case',
              path: options.androidPath,
            },
          }
        : {}),
      ...(options.iosPath
        ? {
            ios: {
              enabled: true,
              key_transform: 'identity',
              path: options.iosPath,
            },
          }
        : {}),
    },
    provider: {
      codex_min_version: '0.30.0',
      glossary: {},
      ...(options.providerModel ? { model: options.providerModel } : {}),
      type: 'codex-local',
    },
    source_locale: options.sourceLocale,
    target_locales: options.targetLocales,
    version: 1,
  };
}

export async function runInit(
  rootDir: string,
  explicitConfigPath: string | undefined,
  options: {
    androidPath?: string;
    importExisting?: boolean;
    importFrom?: ImportSource;
    iosPath?: string;
    providerModel?: string;
    sourceLocale?: string;
    targetLocales?: string[];
  } = {},
): Promise<InitReport> {
  const configPath = resolve(rootDir, explicitConfigPath ?? 'l10n/config.yaml');
  if (await pathExists(configPath)) {
    throw new L10nError({
      code: 'L10N_E0003',
      details: { path: configPath },
      level: 'error',
      next: 'Remove the existing config or run the other l10n-agent commands against the initialized repo.',
      summary: 'Project is already initialized',
    });
  }

  const detected = await detectPlatformPaths(rootDir);
  const iosPath = options.iosPath ?? detected.ios;
  const androidPath = options.androidPath ?? detected.android;
  if (!iosPath && !androidPath) {
    throw new L10nError({
      code: 'L10N_E0030',
      details: { root: rootDir },
      level: 'error',
      next: 'Pass --ios-path and/or --android-path so init knows which platform files to manage.',
      summary: 'Init could not detect any platform localization files',
    });
  }

  const sourceLocale = options.sourceLocale ?? 'en';
  const targetLocales = [...new Set(options.targetLocales ?? [])];
  const effectiveTargetLocales =
    targetLocales.length > 0
      ? targetLocales
      : sourceLocale === 'en'
        ? ['de', 'es']
        : ['en'];

  const l10nDir = dirname(configPath);
  const sourcePath = resolve(l10nDir, `source.${sourceLocale}.json`);
  const translationPaths = effectiveTargetLocales.map((locale) => resolve(l10nDir, `translations.${locale}.json`));
  const historyPath = resolve(l10nDir, '.history.jsonl');
  const initTimestamp = new Date().toISOString();
  const initHistoryId = buildHistoryId(initTimestamp, 'init');

  await snapshotManagedFiles(rootDir, l10nDir, initHistoryId, [
    configPath,
    historyPath,
    sourcePath,
    ...translationPaths,
    ...(iosPath ? [resolve(rootDir, iosPath)] : []),
    ...(androidPath ? [resolve(rootDir, androidPath)] : []),
  ]);

  const config = buildConfig({
    androidPath,
    iosPath,
    ...(options.providerModel ? { providerModel: options.providerModel } : {}),
    sourceLocale,
    targetLocales: effectiveTargetLocales,
  });
  await writeTextFileAtomic(configPath, YAML.stringify(config));
  await writeTextFileAtomic(sourcePath, JSON.stringify({ keys: {}, version: 1 }, null, 2) + '\n');
  for (const locale of effectiveTargetLocales) {
    await writeTextFileAtomic(
      resolve(l10nDir, `translations.${locale}.json`),
      JSON.stringify(createTranslationFile(locale), null, 2) + '\n',
    );
  }
  await appendHistoryEntries(historyPath, [
    createInitHistoryEntry(
      initHistoryId,
      initTimestamp,
      `Initialized l10n workspace for ${sourceLocale} -> ${effectiveTargetLocales.join(', ')}`,
    ),
  ]);

  const importFrom =
    options.importExisting === false
      ? null
      : options.importFrom ?? (iosPath ? 'xcstrings' : androidPath ? 'android' : null);

  if (importFrom) {
    const snapshot = await loadProjectSnapshot(rootDir, explicitConfigPath);
    await runImport(snapshot, { from: importFrom });
  }

  return {
    imported_from: importFrom,
    ok: true,
    preflight: await codexPreflight(config.provider.codex_min_version),
    summary: {
      config_path: configPath,
      source_locale: sourceLocale,
      target_locales: effectiveTargetLocales,
    },
  };
}
