import { cp, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { buildSyncPlan } from '../../../src/core/sync.js';
import { computeConfigHash } from '../../../src/core/store/hash.js';
import { loadProjectSnapshot } from '../../../src/core/store/load.js';
import { stableStringify } from '../../../src/utils/json.js';

async function createTempProject(name: string): Promise<string> {
  const targetDir = await mkdtemp(join(tmpdir(), `l10n-agent-load-${name}-`));
  await cp(resolve('fixtures/projects/happy-path'), targetDir, { recursive: true });
  return targetDir;
}

describe('loadProjectSnapshot', () => {
  it('ignores a trailing corrupt history line and surfaces a warning diagnostic', async () => {
    const projectDir = await createTempProject('history-warning');
    const historyPath = join(projectDir, 'l10n/.history.jsonl');
    await writeFile(
      historyPath,
      `${JSON.stringify({
        actor: 'test',
        id: '20260418T100000Z-sync',
        op: 'sync',
        summary: 'ok',
        ts: '2026-04-18T10:00:00.000Z',
      })}\n{"truncated": true`,
      'utf8',
    );

    const snapshot = await loadProjectSnapshot(projectDir);

    expect(snapshot.history.value).toHaveLength(1);
    expect(snapshot.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: 'L10N_E0078',
        }),
      ]),
    );
  });

  it('discards stale resume state when the source or config fingerprint changed', async () => {
    const projectDir = await createTempProject('stale-state');
    const snapshot = await loadProjectSnapshot(projectDir);
    const statePath = join(projectDir, 'l10n/.state.json');

    await writeFile(
      statePath,
      stableStringify({
        batch_index: 0,
        completed_translations: 0,
        config_hash: computeConfigHash(snapshot.config),
        pid: process.pid,
        source_hash: 'sha256:1111111111111111111111111111111111111111111111111111111111111111',
        started_at: '2026-04-18T10:00:00.000Z',
        status: 'running',
        total_translations: 1,
        updated_at: '2026-04-18T10:01:00.000Z',
        version: 1,
      }),
      'utf8',
    );

    const refreshed = await loadProjectSnapshot(projectDir);

    expect(refreshed.state.exists).toBe(false);
    expect(refreshed.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: 'L10N_E0080',
        }),
      ]),
    );
  });

  it('migrates v1 cache entries and preserves model versions that contain pipes', async () => {
    const projectDir = await createTempProject('cache-migration');
    const cachePath = join(projectDir, 'l10n/.cache.json');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, {
        description?: string;
        placeholders: Record<string, unknown>;
        text: string;
      }>;
      version: number;
    };
    source.keys['settings.notifications.title'] = {
      description: 'Settings screen notification row title.',
      placeholders: {},
      text: 'Notifications',
    };
    await writeFile(sourcePath, stableStringify(source), 'utf8');

    const updatedSnapshot = await loadProjectSnapshot(projectDir);
    const notificationHash = updatedSnapshot.source.hashes.get('settings.notifications.title');
    await writeFile(
      cachePath,
      stableStringify({
        entries: {
          [`${notificationHash}|de|gpt-5|rc1`]: {
            cached_at: '2026-04-18T10:00:00.000Z',
            text: 'Benachrichtigungen',
          },
        },
        version: 1,
      }),
      'utf8',
    );

    const refreshed = await loadProjectSnapshot(projectDir);
    const plan = buildSyncPlan(refreshed);

    expect(refreshed.cache.value?.version).toBe(2);
    expect(refreshed.cache.value?.entries).toEqual([
      expect.objectContaining({
        locale: 'de',
        model_version: 'gpt-5|rc1',
        source_hash: notificationHash,
      }),
    ]);
    expect(plan.total_cache_hits).toBe(1);
  });
});
