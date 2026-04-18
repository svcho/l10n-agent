import { cp, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { AndroidStringsAdapter } from '../../src/adapters/android/strings.js';
import { IosXcstringsAdapter } from '../../src/adapters/ios/xcstrings.js';
import { buildCheckReport } from '../../src/core/check.js';
import { loadProjectSnapshot } from '../../src/core/store/load.js';
import { runSync } from '../../src/core/sync.js';
import { ReplayCodexExecTransport, CodexLocalProvider } from '../../src/providers/codex-local.js';
import { stableStringify } from '../../src/utils/json.js';

async function createTempProject(name: string): Promise<string> {
  const targetDir = await mkdtemp(join(tmpdir(), `l10n-agent-${name}-`));
  await cp(resolve('fixtures/projects/happy-path'), targetDir, { recursive: true });
  return targetDir;
}

async function updateSourceFile(
  projectDir: string,
  mutate: (source: {
    keys: Record<string, unknown>;
    version: number;
  }) => void,
): Promise<void> {
  const sourcePath = join(projectDir, 'l10n/source.en.json');
  const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
    keys: Record<string, unknown>;
    version: number;
  };
  mutate(source);
  await writeFile(sourcePath, stableStringify(source), 'utf8');
}

async function createReplayProvider(projectDir: string, fixtureName: string): Promise<CodexLocalProvider> {
  return new CodexLocalProvider({
    cwd: projectDir,
    minimumVersion: '0.30.0',
    preflightCheck: async () => ({
      detectedVersion: '0.121.0',
      loginStatus: 'logged-in',
      meetsMinimumVersion: true,
      minimumVersion: '0.30.0',
    }),
    transport: await ReplayCodexExecTransport.fromFile(resolve(`fixtures/provider/${fixtureName}`)),
  });
}

describe('runSync', () => {
  it('syncs missing translations from recorded Codex fixtures and updates both platforms', async () => {
    const projectDir = await createTempProject('sync-success');
    await updateSourceFile(projectDir, (source) => {
      source.keys['settings.notifications.title'] = {
        description: 'Settings screen notification row title.',
        placeholders: {},
        text: 'Notifications',
      };
    });

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = await runSync(snapshot, {
      provider: await createReplayProvider(projectDir, 'sync-success.json'),
    });

    expect(report.ok).toBe(true);
    expect(report.summary.translated).toBe(2);
    expect(report.summary.cache_hits).toBe(0);
    expect(report.resumed_from).toBeNull();

    const refreshed = await loadProjectSnapshot(projectDir);
    const checkReport = await buildCheckReport(refreshed);
    expect(checkReport.ok).toBe(true);

    const deTranslation = refreshed.translations.find((translation) => translation.locale === 'de')?.value;
    const esTranslation = refreshed.translations.find((translation) => translation.locale === 'es')?.value;
    expect(deTranslation?.entries['settings.notifications.title']?.text).toBe('Benachrichtigungen');
    expect(esTranslation?.entries['settings.notifications.title']?.text).toBe('Notificaciones');
    expect(refreshed.cache.value ? Object.keys(refreshed.cache.value.entries) : []).toHaveLength(3);
    expect(refreshed.history.value?.at(-1)?.summary).toContain('2 translations generated');
    expect(refreshed.state.exists).toBe(false);

    const iosAdapter = new IosXcstringsAdapter({
      keyTransform: 'identity',
      sourceLocale: 'en',
    });
    const androidAdapter = new AndroidStringsAdapter({
      keyTransform: 'snake_case',
      sourceLocale: 'en',
    });
    const iosCatalog = await iosAdapter.read(join(projectDir, 'ios/MyApp/Localizable.xcstrings'), 'de');
    const androidCatalog = await androidAdapter.read(
      join(projectDir, 'android/app/src/main/res/values/strings.xml'),
      'es',
    );
    expect(iosCatalog.keys.get('settings.notifications.title')?.text).toBe('Benachrichtigungen');
    expect(androidCatalog.keys.get('settings.notifications.title')?.text).toBe('Notificaciones');
  });

  it('writes partial progress and resumes cleanly after a recorded rate-limit failure', async () => {
    const projectDir = await createTempProject('sync-rate-limit');
    await updateSourceFile(projectDir, (source) => {
      source.keys['settings.notifications.title'] = {
        description: 'Settings screen notification row title.',
        placeholders: {},
        text: 'Notifications',
      };
    });

    const firstSnapshot = await loadProjectSnapshot(projectDir);
    await expect(
      runSync(firstSnapshot, {
        provider: await createReplayProvider(projectDir, 'sync-rate-limit-first-run.json'),
      }),
    ).rejects.toMatchObject({
      diagnostic: {
        code: 'L10N_E0053',
      },
    });

    const interrupted = await loadProjectSnapshot(projectDir);
    expect(interrupted.state.exists).toBe(true);
    expect(interrupted.state.value).toMatchObject({
      completed_translations: 1,
      last_processed_key: 'settings.notifications.title',
      last_processed_locale: 'de',
      total_translations: 2,
    });
    expect(
      interrupted.translations.find((translation) => translation.locale === 'de')?.value?.entries[
        'settings.notifications.title'
      ]?.text,
    ).toBe('Benachrichtigungen');
    expect(
      interrupted.translations.find((translation) => translation.locale === 'es')?.value?.entries[
        'settings.notifications.title'
      ],
    ).toBeUndefined();
    expect(interrupted.history.value?.at(-1)?.summary).toContain('1 of 2 translations completed');

    const resumedSnapshot = await loadProjectSnapshot(projectDir);
    const resumedReport = await runSync(resumedSnapshot, {
      provider: await createReplayProvider(projectDir, 'sync-rate-limit-resume.json'),
    });

    expect(resumedReport.ok).toBe(true);
    expect(resumedReport.resumed_from).toEqual({
      remaining_translations: 1,
      started_at: interrupted.state.value?.started_at,
    });

    const refreshed = await loadProjectSnapshot(projectDir);
    const checkReport = await buildCheckReport(refreshed);
    expect(checkReport.ok).toBe(true);
    expect(refreshed.state.exists).toBe(false);
    expect(
      refreshed.translations.find((translation) => translation.locale === 'es')?.value?.entries[
        'settings.notifications.title'
      ]?.text,
    ).toBe('Notificaciones');
  });

  it('skips placeholder-mismatched translations while applying other successful locales', async () => {
    const projectDir = await createTempProject('sync-placeholder');
    await updateSourceFile(projectDir, (source) => {
      source.keys['onboarding.greeting.title'] = {
        description: 'Personal greeting at the top of onboarding.',
        placeholders: {
          name: {
            example: 'Jacob',
            type: 'string',
          },
        },
        text: 'Hello, {name}',
      };
    });

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = await runSync(snapshot, {
      provider: await createReplayProvider(projectDir, 'sync-placeholder-mismatch.json'),
    });

    expect(report.ok).toBe(false);
    expect(report.summary.translated).toBe(1);
    expect(report.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: 'L10N_E0041',
        }),
      ]),
    );

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(
      refreshed.translations.find((translation) => translation.locale === 'de')?.value?.entries[
        'onboarding.greeting.title'
      ],
    ).toBeUndefined();
    expect(
      refreshed.translations.find((translation) => translation.locale === 'es')?.value?.entries[
        'onboarding.greeting.title'
      ]?.text,
    ).toBe('Hola, {name}');
    expect(refreshed.state.exists).toBe(false);
  });
});
