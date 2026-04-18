import { cp, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { describe, expect, it, vi } from 'vitest';

import { AndroidStringsAdapter } from '../../src/adapters/android/strings.js';
import { IosXcstringsAdapter } from '../../src/adapters/ios/xcstrings.js';
import { buildCanonicalKeySetFromTranslation } from '../../src/adapters/canonical.js';
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
    expect(refreshed.cache.value?.entries ?? []).toHaveLength(3);
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

  it('persists in-flight sync status and emits progress updates while translations are running', async () => {
    const projectDir = await createTempProject('sync-progress');
    await updateSourceFile(projectDir, (source) => {
      source.keys['settings.notifications.title'] = {
        description: 'Settings screen notification row title.',
        placeholders: {},
        text: 'Notifications',
      };
    });

    const snapshot = await loadProjectSnapshot(projectDir);
    const progress: string[] = [];
    let releaseFirstTranslation: (() => void) | null = null;
    let markFirstTranslationStarted: (() => void) | null = null;
    const firstTranslationStarted = new Promise<void>((resolve) => {
      markFirstTranslationStarted = resolve;
    });

    const syncPromise = runSync(snapshot, {
      onProgress(update) {
        progress.push(update.message);
      },
      provider: {
        id: 'test-provider',
        preflight: async () => ({ ok: true }),
        translate: async (request) => {
          if (request.targetLocale === 'de' && releaseFirstTranslation === null) {
            markFirstTranslationStarted?.();
            await new Promise<void>((resolve) => {
              releaseFirstTranslation = resolve;
            });
          }

          return {
            modelVersion: 'test-model',
            text: request.targetLocale === 'de' ? 'Benachrichtigungen' : 'Notificaciones',
          };
        },
      },
    });

    await firstTranslationStarted;

    const midRunSnapshot = await loadProjectSnapshot(projectDir);
    expect(midRunSnapshot.state.value).toMatchObject({
      completed_translations: 0,
      current_key: 'settings.notifications.title',
      current_locale: 'de',
      pid: process.pid,
      total_translations: 2,
    });

    releaseFirstTranslation?.();

    const report = await syncPromise;
    expect(report.ok).toBe(true);
    expect(progress).toEqual(
      expect.arrayContaining([
        'Preparing sync for 2 translations',
        'Translating (1/2) de settings.notifications.title',
        'Translating (2/2) es settings.notifications.title',
        'Writing derived translation and platform files',
      ]),
    );

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(refreshed.state.exists).toBe(false);
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

  it('fails with a reviewed-placeholder-divergence diagnostic and keeps the reviewed entry intact', async () => {
    const projectDir = await createTempProject('reviewed-placeholder-divergence');

    await updateSourceFile(projectDir, (source) => {
      source.keys['settings.privacy.title'] = {
        description: 'Settings screen title.',
        placeholders: {
          section: {
            example: 'Privacy',
            type: 'string',
          },
        },
        text: 'Privacy {section}',
      };
    });

    const dePath = join(projectDir, 'l10n/translations.de.json');
    const deTranslation = JSON.parse(await readFile(dePath, 'utf8')) as {
      entries: Record<string, {
        model_version: string;
        provider: string;
        reviewed: boolean;
        source_hash: string;
        stale: boolean;
        text: string;
        translated_at: string;
      }>;
      locale: string;
      version: number;
    };
    deTranslation.entries['settings.privacy.title'].reviewed = true;
    await writeFile(dePath, stableStringify(deTranslation), 'utf8');

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = await runSync(snapshot, {
      provider: await createReplayProvider(projectDir, 'sync-success.json'),
    });

    expect(report.ok).toBe(false);
    expect(report.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: 'L10N_E0082',
        }),
      ]),
    );

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(refreshed.translations.find((translation) => translation.locale === 'de')?.value?.entries['settings.privacy.title'])
      .toMatchObject({
        reviewed: true,
        text: 'Datenschutz',
      });
  });

  it('archives reviewed entries whose source keys were removed instead of dropping them silently', async () => {
    const projectDir = await createTempProject('orphaned-reviewed');

    await updateSourceFile(projectDir, (source) => {
      delete source.keys['settings.privacy.title'];
    });

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = await runSync(snapshot, {
      provider: await createReplayProvider(projectDir, 'sync-success.json'),
    });

    expect(report.ok).toBe(true);
    expect(report.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: 'L10N_E0083',
        }),
      ]),
    );

    const orphanedDir = join(projectDir, 'l10n/.snapshots/orphaned-reviewed');
    const orphanedArchives = await readdir(orphanedDir);
    expect(orphanedArchives).toHaveLength(1);
    const archive = JSON.parse(await readFile(join(orphanedDir, orphanedArchives[0]!), 'utf8')) as {
      entries: Record<string, { reviewed: boolean; text: string }>;
    };
    expect(archive.entries['settings.privacy.title']).toMatchObject({
      reviewed: true,
      text: 'Datenschutz',
    });

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(refreshed.translations.find((translation) => translation.locale === 'de')?.value?.entries['settings.privacy.title'])
      .toBeUndefined();
  });

  it('archives removed locales and strips them from platform files during sync', async () => {
    const projectDir = await createTempProject('sync-remove-locale');
    const configPath = join(projectDir, 'l10n/config.yaml');
    const configWithFr = (await readFile(configPath, 'utf8')).replace('  - es\n', '  - es\n  - fr\n');
    await writeFile(configPath, configWithFr, 'utf8');

    const frTranslationPath = join(projectDir, 'l10n/translations.fr.json');
    await writeFile(
      frTranslationPath,
      JSON.stringify(
        {
          entries: {
            'onboarding.welcome.title': {
              model_version: 'manual',
              provider: 'human',
              reviewed: true,
              source_hash: 'sha256:ae7593171bfe263eb9f504282b37fe29fa76e638ac6e604f1cc6585eff49d9b6',
              stale: false,
              text: 'Bienvenue chez vous, {name}',
              translated_at: '2026-04-18T12:07:00Z',
            },
            'settings.privacy.title': {
              model_version: 'manual',
              provider: 'human',
              reviewed: true,
              source_hash: 'sha256:9c432d31bfec7bccb6b1c0682109da54c2b0d107434f68c2ebb15a7cb08baee0',
              stale: false,
              text: 'Confidentialite',
              translated_at: '2026-04-18T12:07:00Z',
            },
          },
          locale: 'fr',
          version: 1,
        },
        null,
        2,
      ) + '\n',
      'utf8',
    );

    const withFrSnapshot = await loadProjectSnapshot(projectDir);
    const frTranslation = withFrSnapshot.translations.find((translation) => translation.locale === 'fr')?.value;
    expect(frTranslation).toBeTruthy();

    const iosAdapter = new IosXcstringsAdapter({
      keyTransform: 'identity',
      sourceLocale: 'en',
    });
    const androidAdapter = new AndroidStringsAdapter({
      keyTransform: 'snake_case',
      sourceLocale: 'en',
    });
    await iosAdapter.write(
      join(projectDir, 'ios/MyApp/Localizable.xcstrings'),
      buildCanonicalKeySetFromTranslation(frTranslation!, withFrSnapshot.source.value),
      'fr',
    );
    await androidAdapter.write(
      join(projectDir, 'android/app/src/main/res/values/strings.xml'),
      buildCanonicalKeySetFromTranslation(frTranslation!, withFrSnapshot.source.value),
      'fr',
    );

    const configWithoutFr = (await readFile(configPath, 'utf8')).replace('  - fr\n', '');
    await writeFile(configPath, configWithoutFr, 'utf8');

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = await runSync(snapshot, {
      provider: await createReplayProvider(projectDir, 'sync-success.json'),
    });

    expect(report.ok).toBe(true);

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(refreshed.translations.find((translation) => translation.locale === 'fr')).toBeUndefined();
    await expect(readFile(frTranslationPath, 'utf8')).rejects.toMatchObject({ code: 'ENOENT' });

    const archiveDir = join(projectDir, 'l10n/.archive');
    const archiveEntries = (await readdir(archiveDir)).filter((entry) => entry.startsWith('translations.fr.'));
    expect(archiveEntries).toHaveLength(1);

    const iosFrench = await iosAdapter.read(join(projectDir, 'ios/MyApp/Localizable.xcstrings'), 'fr');
    expect(iosFrench.keys.size).toBe(0);

    const androidFrenchPath = join(projectDir, 'android/app/src/main/res/values-fr/strings.xml');
    await expect(readFile(androidFrenchPath, 'utf8')).rejects.toMatchObject({ code: 'ENOENT' });
    expect(refreshed.history.value?.some((entry) => entry.op === 'remove_locale' && entry.locale === 'fr')).toBe(
      true,
    );
  });

  it('avoids archive-path collisions when the same archive timestamp already exists', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-04-18T12:34:56.000Z'));

    try {
      const projectDir = await createTempProject('archive-collision');
      const configPath = join(projectDir, 'l10n/config.yaml');
      const configWithFr = (await readFile(configPath, 'utf8')).replace('  - es\n', '  - es\n  - fr\n');
      await writeFile(configPath, configWithFr, 'utf8');

      const frTranslationPath = join(projectDir, 'l10n/translations.fr.json');
      await writeFile(
        frTranslationPath,
        JSON.stringify(
          {
            entries: {
              'settings.privacy.title': {
                model_version: 'manual',
                provider: 'human',
                reviewed: true,
                source_hash: 'sha256:9c432d31bfec7bccb6b1c0682109da54c2b0d107434f68c2ebb15a7cb08baee0',
                stale: false,
                text: 'Confidentialite',
                translated_at: '2026-04-18T12:07:00Z',
              },
            },
            locale: 'fr',
            version: 1,
          },
          null,
          2,
        ) + '\n',
        'utf8',
      );

      const existingArchivePath = join(projectDir, 'l10n/.archive/translations.fr.20260418123456.json');
      await mkdir(join(projectDir, 'l10n/.archive'), { recursive: true });
      await writeFile(existingArchivePath, '{}\n', 'utf8');
      const configWithoutFr = (await readFile(configPath, 'utf8')).replace('  - fr\n', '');
      await writeFile(configPath, configWithoutFr, 'utf8');

      const snapshot = await loadProjectSnapshot(projectDir);
      const report = await runSync(snapshot, {
        provider: await createReplayProvider(projectDir, 'sync-success.json'),
      });

      expect(report.ok).toBe(true);
      const archiveEntries = (await readdir(join(projectDir, 'l10n/.archive')))
        .filter((entry) => entry.startsWith('translations.fr.20260418123456'));
      expect(archiveEntries.sort()).toEqual([
        'translations.fr.20260418123456-1.json',
        'translations.fr.20260418123456.json',
      ]);
    } finally {
      vi.useRealTimers();
    }
  });
});
