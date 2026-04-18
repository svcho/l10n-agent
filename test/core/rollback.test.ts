import { access, cp, mkdir, mkdtemp, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';

import { describe, expect, it } from 'vitest';

import { runRename } from '../../src/core/rename.js';
import { runRollback } from '../../src/core/rollback.js';
import { resolveManagedSnapshotPath } from '../../src/core/project-files.js';
import { loadProjectSnapshot } from '../../src/core/store/load.js';
import { acquireSyncLock } from '../../src/utils/lock.js';
import { stableStringify } from '../../src/utils/json.js';

async function createTempProject(name: string): Promise<string> {
  const targetDir = await mkdtemp(join(tmpdir(), `l10n-agent-rollback-${name}-`));
  await cp(resolve('fixtures/projects/happy-path'), targetDir, { recursive: true });
  return targetDir;
}

/** Returns the id of the latest history entry. */
async function getLatestHistoryId(projectDir: string): Promise<string> {
  const snapshot = await loadProjectSnapshot(projectDir);
  const id = snapshot.history.value?.at(-1)?.id;
  if (!id) {
    throw new Error('No history entry found');
  }
  return id;
}

/** Counts snapshot files in l10n/.snapshots/. */
async function countSnapshotFiles(projectDir: string): Promise<number> {
  const snapshotsDir = join(projectDir, 'l10n/.snapshots');
  try {
    const entries = await readdir(snapshotsDir);
    return entries.filter((e) => e.endsWith('.json')).length;
  } catch {
    return 0;
  }
}

describe('runRollback', () => {
  it('restores files to the pre-rename state and appends a rollback history entry', async () => {
    const projectDir = await createTempProject('happy-path');
    const beforeRename = await loadProjectSnapshot(projectDir);

    // Create a history entry with a real snapshot via runRename.
    await runRename(beforeRename, {
      from: 'onboarding.welcome.title',
      to: 'onboarding.hero.title',
    });

    const afterRename = await loadProjectSnapshot(projectDir);
    const renameId = afterRename.history.value?.at(-1)?.id;
    expect(renameId).toBeTruthy();

    // Rollback to the pre-rename state.
    const report = await runRollback(afterRename, { to: renameId! });
    expect(report.ok).toBe(true);
    expect(report.summary.restored_to).toBe(renameId);

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(refreshed.source.value.keys['onboarding.welcome.title']?.text).toBe('Welcome home, {name}');
    expect(refreshed.source.value.keys['onboarding.hero.title']).toBeUndefined();
    expect(refreshed.history.value?.at(-1)).toMatchObject({
      op: 'rollback',
      to: renameId,
    });
  });

  it('throws L10N_E0062 when the target history entry is not found', async () => {
    const projectDir = await createTempProject('missing-history');
    const snapshot = await loadProjectSnapshot(projectDir);

    await expect(runRollback(snapshot, { to: 'nonexistent-id' })).rejects.toMatchObject({
      diagnostic: { code: 'L10N_E0062' },
    });
  });

  it('throws L10N_E0062 when the target snapshot file is missing and does NOT create a recovery snapshot', async () => {
    const projectDir = await createTempProject('missing-snapshot');
    const beforeRename = await loadProjectSnapshot(projectDir);

    await runRename(beforeRename, {
      from: 'onboarding.welcome.title',
      to: 'onboarding.hero.title',
    });

    const afterRename = await loadProjectSnapshot(projectDir);
    const renameId = afterRename.history.value?.at(-1)?.id;
    expect(renameId).toBeTruthy();

    // Delete the snapshot file for the target history entry.
    const snapshotPath = resolveManagedSnapshotPath(join(projectDir, 'l10n'), renameId!);
    await import('node:fs/promises').then(({ rm }) => rm(snapshotPath, { force: true }));

    const snapshotsBefore = await countSnapshotFiles(projectDir);

    await expect(runRollback(afterRename, { to: renameId! })).rejects.toMatchObject({
      diagnostic: { code: 'L10N_E0062' },
    });

    // Critically: no new snapshot file should have been created.
    const snapshotsAfter = await countSnapshotFiles(projectDir);
    expect(snapshotsAfter).toBe(snapshotsBefore);
  });

  it('throws L10N_E0062 when the snapshot file is malformed and does NOT create a recovery snapshot', async () => {
    const projectDir = await createTempProject('malformed-snapshot');
    const beforeRename = await loadProjectSnapshot(projectDir);

    await runRename(beforeRename, {
      from: 'onboarding.welcome.title',
      to: 'onboarding.hero.title',
    });

    const afterRename = await loadProjectSnapshot(projectDir);
    const renameId = afterRename.history.value?.at(-1)?.id;
    expect(renameId).toBeTruthy();

    // Overwrite the snapshot with invalid content.
    const snapshotPath = resolveManagedSnapshotPath(join(projectDir, 'l10n'), renameId!);
    await writeFile(snapshotPath, stableStringify({ version: 99, broken: true }), 'utf8');

    const snapshotsBefore = await countSnapshotFiles(projectDir);

    await expect(runRollback(afterRename, { to: renameId! })).rejects.toMatchObject({
      diagnostic: { code: 'L10N_E0062' },
    });

    // No new recovery snapshot should have been written.
    const snapshotsAfter = await countSnapshotFiles(projectDir);
    expect(snapshotsAfter).toBe(snapshotsBefore);
  });

  it('throws L10N_E0062 when the snapshot contains a path-traversal entry', async () => {
    const projectDir = await createTempProject('traversal');
    const beforeRename = await loadProjectSnapshot(projectDir);

    await runRename(beforeRename, {
      from: 'onboarding.welcome.title',
      to: 'onboarding.hero.title',
    });

    const afterRename = await loadProjectSnapshot(projectDir);
    const renameId = afterRename.history.value?.at(-1)?.id;
    expect(renameId).toBeTruthy();

    // Inject a path-traversal key into the snapshot.
    const snapshotPath = resolveManagedSnapshotPath(join(projectDir, 'l10n'), renameId!);
    const original = JSON.parse(await import('node:fs/promises').then(({ readFile }) =>
      readFile(snapshotPath, 'utf8'),
    )) as { files: Record<string, unknown>; version: number };
    original.files[`..${sep}evil.txt`] = 'pwned';
    await writeFile(snapshotPath, stableStringify(original), 'utf8');

    await expect(runRollback(afterRename, { to: renameId! })).rejects.toMatchObject({
      diagnostic: {
        code: 'L10N_E0062',
        summary: expect.stringContaining('escapes the project root'),
      },
    });
  });

  it('throws L10N_E0079 when another sync holds the lock', async () => {
    const projectDir = await createTempProject('lock-contention');
    const beforeRename = await loadProjectSnapshot(projectDir);

    await runRename(beforeRename, {
      from: 'onboarding.welcome.title',
      to: 'onboarding.hero.title',
    });

    const afterRename = await loadProjectSnapshot(projectDir);
    const renameId = afterRename.history.value?.at(-1)?.id;
    expect(renameId).toBeTruthy();

    // Simulate a concurrent sync by acquiring the lock first.
    const l10nDir = join(projectDir, 'l10n');
    const lock = await acquireSyncLock(l10nDir);
    try {
      await expect(runRollback(afterRename, { to: renameId! })).rejects.toMatchObject({
        diagnostic: { code: 'L10N_E0079' },
      });
    } finally {
      await lock.release().catch(() => undefined);
    }
  });
});
