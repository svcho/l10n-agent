import { cp, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { buildStatusReport } from '../../src/core/status.js';
import { computeSourceHash } from '../../src/core/store/hash.js';
import { loadProjectSnapshot } from '../../src/core/store/load.js';
import { stableStringify } from '../../src/utils/json.js';

async function createTempProject(name: string): Promise<string> {
  const targetDir = await mkdtemp(join(tmpdir(), `l10n-agent-${name}-`));
  await cp(resolve('fixtures/projects/happy-path'), targetDir, { recursive: true });
  return targetDir;
}

describe('buildStatusReport', () => {
  it('reports idle status when no sync is running', async () => {
    const projectDir = await createTempProject('status-idle');
    const snapshot = await loadProjectSnapshot(projectDir);
    const report = buildStatusReport(snapshot);

    expect(report.ok).toBe(true);
    expect(report.active_sync).toBeNull();
    expect(report.summary.sync_state).toBe('idle');
    expect(report.summary.pending_tasks).toBe(0);
  });

  it('reports running sync progress from the persisted state file', async () => {
    const projectDir = await createTempProject('status-running');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const dePath = join(projectDir, 'l10n/translations.de.json');
    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, unknown>;
      version: number;
    };
    const de = JSON.parse(await readFile(dePath, 'utf8')) as {
      entries: Record<string, unknown>;
      locale: string;
      version: number;
    };
    source.keys['settings.notifications.title'] = {
      description: 'Settings screen notification row title.',
      placeholders: {},
      text: 'Notifications',
    };
    const notificationsSourceKey = source.keys['settings.notifications.title'] as {
      description?: string;
      placeholders: Record<string, unknown>;
      text: string;
    };
    de.entries['settings.notifications.title'] = {
      model_version: 'test-model',
      provider: 'test-provider',
      reviewed: false,
      source_hash: computeSourceHash(notificationsSourceKey),
      stale: false,
      text: 'Benachrichtigungen',
      translated_at: '2026-04-18T10:00:30.000Z',
    };
    await writeFile(sourcePath, stableStringify(source), 'utf8');
    await writeFile(dePath, stableStringify(de), 'utf8');

    const statePath = join(projectDir, 'l10n/.state.json');
    await writeFile(
      statePath,
      stableStringify({
        batch_index: 1,
        completed_translations: 1,
        current_key: 'settings.notifications.title',
        current_locale: 'es',
        last_processed_key: 'settings.notifications.title',
        last_processed_locale: 'de',
        pid: process.pid,
        started_at: '2026-04-18T10:00:00.000Z',
        total_translations: 2,
        updated_at: '2026-04-18T10:01:00.000Z',
        version: 1,
      }),
      'utf8',
    );

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = buildStatusReport(snapshot);

    expect(report.summary.sync_state).toBe('running');
    expect(report.active_sync).toMatchObject({
      completed_translations: 1,
      current_key: 'settings.notifications.title',
      current_locale: 'es',
      percent_complete: 50,
      remaining_translations: 1,
      state: 'running',
      total_translations: 2,
    });
    expect(report.summary.pending_tasks).toBe(1);
    expect(report.summary.provider_requests).toBe(1);
  });

  it('reports interrupted sync progress when the state file is stale', async () => {
    const projectDir = await createTempProject('status-interrupted');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const dePath = join(projectDir, 'l10n/translations.de.json');
    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, unknown>;
      version: number;
    };
    const de = JSON.parse(await readFile(dePath, 'utf8')) as {
      entries: Record<string, unknown>;
      locale: string;
      version: number;
    };
    source.keys['settings.notifications.title'] = {
      description: 'Settings screen notification row title.',
      placeholders: {},
      text: 'Notifications',
    };
    const notificationsSourceKey = source.keys['settings.notifications.title'] as {
      description?: string;
      placeholders: Record<string, unknown>;
      text: string;
    };
    de.entries['settings.notifications.title'] = {
      model_version: 'test-model',
      provider: 'test-provider',
      reviewed: false,
      source_hash: computeSourceHash(notificationsSourceKey),
      stale: false,
      text: 'Benachrichtigungen',
      translated_at: '2026-04-18T10:00:30.000Z',
    };
    await writeFile(sourcePath, stableStringify(source), 'utf8');
    await writeFile(dePath, stableStringify(de), 'utf8');

    const statePath = join(projectDir, 'l10n/.state.json');
    await writeFile(
      statePath,
      stableStringify({
        batch_index: 1,
        completed_translations: 1,
        last_processed_key: 'settings.notifications.title',
        last_processed_locale: 'de',
        started_at: '2026-04-18T10:00:00.000Z',
        total_translations: 2,
        updated_at: '2026-04-18T10:01:00.000Z',
        version: 1,
      }),
      'utf8',
    );

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = buildStatusReport(snapshot);

    expect(report.summary.sync_state).toBe('interrupted');
    expect(report.active_sync).toMatchObject({
      completed_translations: 1,
      state: 'interrupted',
      total_translations: 2,
    });
  });
});
