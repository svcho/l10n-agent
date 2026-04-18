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

  it('drops legacy v1 cache files with a warn diagnostic instead of migrating them', async () => {
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

    // v1 cache is now silently dropped so that all entries are re-fetched with the current config hash.
    expect(refreshed.cache.value?.version).toBe(3);
    expect(refreshed.cache.value?.entries).toHaveLength(0);
    expect(plan.total_cache_hits).toBe(0);
    expect(refreshed.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ code: 'L10N_E0086' }),
      ]),
    );
  });

  it('drops legacy v2 cache files with a warn diagnostic', async () => {
    const projectDir = await createTempProject('cache-migration-v2');
    const cachePath = join(projectDir, 'l10n/.cache.json');

    await writeFile(
      cachePath,
      stableStringify({
        entries: [
          {
            cached_at: '2026-04-18T10:00:00.000Z',
            locale: 'de',
            model_version: 'gpt-5',
            source_hash: 'sha256:ae7593171bfe263eb9f504282b37fe29fa76e638ac6e604f1cc6585eff49d9b6',
            text: 'Benachrichtigungen',
          },
        ],
        version: 2,
      }),
      'utf8',
    );

    const snapshot = await loadProjectSnapshot(projectDir);

    expect(snapshot.cache.value?.version).toBe(3);
    expect(snapshot.cache.value?.entries).toHaveLength(0);
    expect(snapshot.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ code: 'L10N_E0086' }),
      ]),
    );
  });

  it('accepts a valid v3 cache file and uses its entries for cache hits', async () => {
    const projectDir = await createTempProject('cache-v3-roundtrip');
    const cachePath = join(projectDir, 'l10n/.cache.json');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, unknown>;
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

    // Write a correctly-shaped v3 cache file that matches the current config hash.
    const { computeProviderCacheKeyHash } = await import('../../../src/core/store/hash.js');
    const configHash = computeProviderCacheKeyHash(updatedSnapshot.config);

    await writeFile(
      cachePath,
      stableStringify({
        entries: [
          {
            cached_at: '2026-04-18T10:00:00.000Z',
            config_hash: configHash,
            locale: 'de',
            model_version: 'gpt-5',
            source_hash: notificationHash,
            text: 'Benachrichtigungen',
          },
        ],
        version: 3,
      }),
      'utf8',
    );

    const refreshed = await loadProjectSnapshot(projectDir);
    const plan = buildSyncPlan(refreshed);

    expect(refreshed.cache.value?.version).toBe(3);
    expect(refreshed.cache.value?.entries).toHaveLength(1);
    expect(plan.total_cache_hits).toBe(1);
    expect(refreshed.diagnostics.some((d) => d.code === 'L10N_E0086')).toBe(false);
  });
});
