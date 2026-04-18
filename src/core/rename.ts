import { lintSourceKeys } from './linter/lint-keys.js';
import type { Diagnostic } from './diagnostics.js';
import { hasErrorDiagnostics } from './diagnostics.js';
import { buildHistoryId, createRenameHistoryEntry } from './history.js';
import {
  getManagedFilePaths,
  snapshotManagedFiles,
  writeProjectFiles,
  type TranslationLocaleState,
} from './project-files.js';
import type { ProjectSnapshot } from './store/load.js';
import type { SourceFile } from './store/schemas.js';
import { appendHistoryEntries } from './store/write.js';
import { L10nError } from '../errors/l10n-error.js';

export interface RenameReport {
  diagnostics: Diagnostic[];
  ok: boolean;
  summary: {
    from: string;
    locales_touched: number;
    to: string;
  };
}

function moveRecordKey<T>(record: Record<string, T>, fromKey: string, toKey: string): Record<string, T> {
  const entries = Object.entries(record)
    .filter(([key]) => key !== fromKey)
    .map(([key, value]) => [key, value] as const);
  const movedValue = record[fromKey];
  if (movedValue !== undefined) {
    entries.push([toKey, movedValue]);
  }

  return Object.fromEntries(entries);
}

export async function runRename(
  snapshot: ProjectSnapshot,
  options: {
    dryRun?: boolean;
    from: string;
    to: string;
  },
): Promise<RenameReport> {
  if (!(options.from in snapshot.source.value.keys)) {
    throw new L10nError({
      code: 'L10N_E0069',
      details: { key: options.from },
      level: 'error',
      next: 'Choose an existing canonical source key to rename.',
      summary: 'Rename source key does not exist',
    });
  }

  if (options.to in snapshot.source.value.keys) {
    throw new L10nError({
      code: 'L10N_E0069',
      details: { key: options.to },
      level: 'error',
      next: 'Choose a destination key that is not already present in source.en.json.',
      summary: 'Rename destination key already exists',
    });
  }

  const source: SourceFile = {
    ...snapshot.source.value,
    keys: moveRecordKey(snapshot.source.value.keys, options.from, options.to),
  };
  const diagnostics = lintSourceKeys(snapshot.config, source);

  const translations: TranslationLocaleState[] = snapshot.translations.map((translation) => ({
    entries: translation.value ? moveRecordKey(translation.value.entries, options.from, options.to) : {},
    locale: translation.locale,
    path: translation.path,
  }));

  const report: RenameReport = {
    diagnostics,
    ok: !hasErrorDiagnostics(diagnostics),
    summary: {
      from: options.from,
      locales_touched: translations.filter((translation) => options.to in translation.entries).length,
      to: options.to,
    },
  };

  if (options.dryRun || !report.ok) {
    return report;
  }

  const timestamp = new Date().toISOString();
  const historyId = buildHistoryId(timestamp, 'rename');
  await snapshotManagedFiles(snapshot.rootDir, snapshot.l10nDir, historyId, getManagedFilePaths(snapshot));
  await writeProjectFiles(snapshot, source, translations);
  await appendHistoryEntries(snapshot.history.path, snapshot.history.value, [
    createRenameHistoryEntry(historyId, timestamp, options.from, options.to),
  ]);

  return report;
}
