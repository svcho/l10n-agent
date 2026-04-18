import { L10nError } from '../errors/l10n-error.js';
import { acquireSyncLock } from '../utils/lock.js';
import { buildHistoryId, createRollbackHistoryEntry } from './history.js';
import {
  getManagedFilePathsWithExtras,
  getSnapshotTrackedFilePaths,
  restoreManagedFiles,
  snapshotManagedFiles,
  validateManagedSnapshot,
} from './project-files.js';
import type { ProjectSnapshot } from './store/load.js';
import { appendHistoryEntries } from './store/write.js';

export interface RollbackReport {
  ok: boolean;
  summary: {
    restored_to: string;
  };
}

export async function runRollback(
  snapshot: ProjectSnapshot,
  options: {
    to: string;
  },
): Promise<RollbackReport> {
  const targetEntry = snapshot.history.value?.find((entry) => entry.id === options.to);
  if (!targetEntry) {
    throw new L10nError({
      code: 'L10N_E0062',
      details: { history_id: options.to },
      level: 'error',
      next: 'Choose a history entry id from l10n/.history.jsonl.',
      summary: 'Rollback target history entry was not found',
    });
  }

  const lock = await acquireSyncLock(snapshot.l10nDir);
  try {
    // Validate the target snapshot before taking any recovery snapshot so we
    // don't leave useless files in .snapshots/ if the target is malformed.
    await validateManagedSnapshot(snapshot.rootDir, snapshot.l10nDir, options.to);

    const timestamp = new Date().toISOString();
    const historyId = buildHistoryId(timestamp, 'rollback');
    const trackedPaths = await getSnapshotTrackedFilePaths(snapshot.rootDir, snapshot.l10nDir, options.to);
    await snapshotManagedFiles(
      snapshot.rootDir,
      snapshot.l10nDir,
      historyId,
      getManagedFilePathsWithExtras(snapshot, trackedPaths),
    );
    await restoreManagedFiles(snapshot.rootDir, snapshot.l10nDir, options.to);
    await appendHistoryEntries(snapshot.history.path, snapshot.history.value, [
      createRollbackHistoryEntry(historyId, timestamp, options.to),
    ]);
  } finally {
    await lock.release().catch(() => undefined);
  }

  return {
    ok: true,
    summary: {
      restored_to: targetEntry.id,
    },
  };
}
