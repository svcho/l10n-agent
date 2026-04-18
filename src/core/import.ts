import { basename } from 'node:path';

import { AndroidStringsAdapter } from '../adapters/android/strings.js';
import { createIosAdapter } from '../adapters/ios/index.js';
import { L10nError } from '../errors/l10n-error.js';
import { computeSourceHash } from './store/hash.js';
import type { ProjectSnapshot } from './store/load.js';
import type { Diagnostic } from './diagnostics.js';
import { buildHistoryId, createImportHistoryEntry } from './history.js';
import {
  getManagedFilePaths,
  snapshotManagedFiles,
  writeProjectFiles,
  type TranslationLocaleState,
} from './project-files.js';
import type { ExtendedCanonicalKeySet } from '../adapters/canonical.js';
import type { SourceFile, TranslationEntry } from './store/schemas.js';
import { appendHistoryEntries } from './store/write.js';

export type ImportSource = 'android' | 'xcstrings';

export interface ImportLocaleReport {
  imported: number;
  locale: string;
  missing: number;
}

export interface ImportReport {
  diagnostics: Diagnostic[];
  ok: boolean;
  summary: {
    from: ImportSource;
    imported_entries: number;
    locales: ImportLocaleReport[];
    source_keys: number;
  };
}

function placeholderRecordFromCanonical(keyValue: { placeholders: Array<{ name: string; type: 'date' | 'number' | 'string' }> }) {
  return Object.fromEntries(
    keyValue.placeholders.map((placeholder) => [
      placeholder.name,
      {
        type: placeholder.type,
      },
    ]),
  );
}

function buildSourceFile(canonical: ExtendedCanonicalKeySet): SourceFile {
  return {
    keys: Object.fromEntries(
      [...canonical.keys.entries()]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, value]) => [
          key,
          {
            ...(value.comment ? { description: value.comment } : {}),
            placeholders: placeholderRecordFromCanonical(value),
            text: value.text,
          },
        ]),
    ),
    version: 1,
  };
}

function createImportedEntry(
  text: string,
  sourceHash: string,
  from: ImportSource,
  translatedAt: string,
): TranslationEntry {
  return {
    model_version: 'import',
    provider: `import:${from}`,
    reviewed: true,
    source_hash: sourceHash,
    stale: false,
    text,
    translated_at: translatedAt,
  };
}

async function readCanonicalForLocale(
  snapshot: ProjectSnapshot,
  from: ImportSource,
  locale: string,
): Promise<ExtendedCanonicalKeySet> {
  if (from === 'xcstrings') {
    if (!snapshot.platformPaths.ios || !snapshot.config.platforms.ios) {
      throw new L10nError({
        code: 'L10N_E0030',
        details: { platform: 'ios' },
        level: 'error',
        next: 'Configure platforms.ios.path in l10n/config.yaml before importing from iOS string files.',
        summary: 'iOS platform path is not configured',
      });
    }

    const adapter = createIosAdapter(snapshot.platformPaths.ios, {
      keyTransform: snapshot.config.platforms.ios.key_transform,
      sourceLocale: snapshot.config.source_locale,
    });
    return adapter.readWithComments(snapshot.platformPaths.ios, locale);
  }

  if (!snapshot.platformPaths.android || !snapshot.config.platforms.android) {
    throw new L10nError({
      code: 'L10N_E0030',
      details: { platform: 'android' },
      level: 'error',
      next: 'Configure platforms.android.path in l10n/config.yaml before importing from android.',
      summary: 'Android platform path is not configured',
    });
  }

  const adapter = new AndroidStringsAdapter({
    keyTransform: snapshot.config.platforms.android.key_transform,
    sourceLocale: snapshot.config.source_locale,
  });
  return adapter.readWithComments(snapshot.platformPaths.android, locale);
}

export async function runImport(
  snapshot: ProjectSnapshot,
  options: {
    dryRun?: boolean;
    from: ImportSource;
  },
): Promise<ImportReport> {
  const sourceCanonical = await readCanonicalForLocale(snapshot, options.from, snapshot.config.source_locale);
  const source = buildSourceFile(sourceCanonical);

  if (Object.keys(source.keys).length === 0) {
    throw new L10nError({
      code: 'L10N_E0010',
      details: { from: options.from },
      level: 'error',
      next: `Add source-locale strings to the configured ${options.from} files, then rerun import.`,
      summary: 'Import source does not contain any source-locale keys',
    });
  }

  const translatedAt = new Date().toISOString();
  const translations: TranslationLocaleState[] = [];
  const localeReports: ImportLocaleReport[] = [];

  for (const translationFile of snapshot.translations) {
    const localeCanonical = await readCanonicalForLocale(snapshot, options.from, translationFile.locale);
    const entries: Record<string, TranslationEntry> = {};

    for (const [key, sourceKey] of Object.entries(source.keys)) {
      const importedValue = localeCanonical.keys.get(key);
      if (!importedValue || importedValue.text.trim().length === 0) {
        continue;
      }

      entries[key] = createImportedEntry(
        importedValue.text,
        computeSourceHash(sourceKey),
        options.from,
        translatedAt,
      );
    }

    translations.push({
      entries,
      locale: translationFile.locale,
      path: translationFile.path,
    });
    localeReports.push({
      imported: Object.keys(entries).length,
      locale: translationFile.locale,
      missing: Object.keys(source.keys).length - Object.keys(entries).length,
    });
  }

  const diagnostics: Diagnostic[] = [...snapshot.diagnostics];
  const report: ImportReport = {
    diagnostics,
    ok: true,
    summary: {
      from: options.from,
      imported_entries: localeReports.reduce((sum, locale) => sum + locale.imported, 0),
      locales: localeReports,
      source_keys: Object.keys(source.keys).length,
    },
  };

  if (options.dryRun) {
    return report;
  }

  const timestamp = new Date().toISOString();
  const historyId = buildHistoryId(timestamp, 'import');
  await snapshotManagedFiles(snapshot.rootDir, snapshot.l10nDir, historyId, getManagedFilePaths(snapshot));
  await writeProjectFiles(snapshot, source, translations, { removeState: true });
  await appendHistoryEntries(snapshot.history.path, snapshot.history.value, [
    createImportHistoryEntry(
      historyId,
      timestamp,
      options.from,
      `Imported ${Object.keys(source.keys).length} source keys and ${report.summary.imported_entries} translations from ${options.from} (${basename(
        options.from === 'xcstrings' ? snapshot.platformPaths.ios ?? 'unknown' : snapshot.platformPaths.android ?? 'unknown',
      )})`,
    ),
  ]);

  return report;
}
