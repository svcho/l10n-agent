import { cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { buildCheckReport } from '../../src/core/check.js';
import { runLintFix } from '../../src/core/lint.js';
import { runRollback } from '../../src/core/rollback.js';
import { loadProjectSnapshot } from '../../src/core/store/load.js';
import { stableStringify } from '../../src/utils/json.js';

async function createTempProject(name: string): Promise<string> {
  const targetDir = await mkdtemp(join(tmpdir(), `l10n-agent-${name}-`));
  await cp(resolve('fixtures/projects/happy-path'), targetDir, { recursive: true });
  return targetDir;
}

async function writeJson(path: string, value: unknown): Promise<void> {
  await writeFile(path, stableStringify(value), 'utf8');
}

describe('runLintFix', () => {
  it('autofixes invalid keys, rewrites code references, and stays rollback-safe', async () => {
    const projectDir = await createTempProject('lint-fix');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const dePath = join(projectDir, 'l10n/translations.de.json');
    const esPath = join(projectDir, 'l10n/translations.es.json');
    const swiftPath = join(projectDir, 'ios/MyApp/WelcomeView.swift');
    const kotlinPath = join(projectDir, 'android/app/src/main/java/com/example/HomeScreen.kt');

    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, { description?: string; placeholders: Record<string, unknown>; text: string }>;
      version: number;
    };
    source.keys = {
      'tmp.WelcomeTitle': source.keys['onboarding.welcome.title']!,
      'settings.privacy-Title': source.keys['settings.privacy.title']!,
    };
    await writeJson(sourcePath, source);

    for (const path of [dePath, esPath]) {
      const translation = JSON.parse(await readFile(path, 'utf8')) as {
        entries: Record<string, Record<string, unknown>>;
        locale: string;
        version: number;
      };
      translation.entries = {
        'tmp.WelcomeTitle': translation.entries['onboarding.welcome.title']!,
        'settings.privacy-Title': translation.entries['settings.privacy.title']!,
      };
      await writeJson(path, translation);
    }

    await mkdir(join(projectDir, 'ios/MyApp'), { recursive: true });
    await mkdir(join(projectDir, 'android/app/src/main/java/com/example'), { recursive: true });
    await writeFile(
      swiftPath,
      [
        'enum Keys {',
        '  static let welcome = "tmp.WelcomeTitle"',
        '  static let privacy = "settings.privacy-Title"',
        '}',
        '',
      ].join('\n'),
      'utf8',
    );
    await writeFile(
      kotlinPath,
      [
        'object Keys {',
        '  const val WELCOME = "tmp.WelcomeTitle"',
        '  const val PRIVACY = "settings.privacy-Title"',
        '}',
        '',
      ].join('\n'),
      'utf8',
    );

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = await runLintFix(snapshot, {
      provider: {
        planKeyRenames: async () => ({
          modelVersion: 'test-model',
          plans: [
            {
              from: 'settings.privacy-Title',
              rationale: 'Restore dotted.lower casing for the privacy title key.',
              to: 'settings.privacy.title',
            },
            {
              from: 'tmp.WelcomeTitle',
              rationale: 'Remove the forbidden prefix and restore the onboarding scope.',
              to: 'onboarding.welcome.title',
            },
          ],
        }),
      },
    });

    expect(report.ok).toBe(true);
    expect(report.fixed_renames).toEqual([
      {
        from: 'settings.privacy-Title',
        rationale: 'Restore dotted.lower casing for the privacy title key.',
        to: 'settings.privacy.title',
      },
      {
        from: 'tmp.WelcomeTitle',
        rationale: 'Remove the forbidden prefix and restore the onboarding scope.',
        to: 'onboarding.welcome.title',
      },
    ]);
    expect(report.summary).toMatchObject({
      fixed_keys: 2,
      reference_files_touched: 2,
      reference_replacements: 4,
    });

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(Object.keys(refreshed.source.value.keys)).toEqual([
      'onboarding.welcome.title',
      'settings.privacy.title',
    ]);
    expect(
      refreshed.translations.find((translation) => translation.locale === 'de')?.value?.entries[
        'onboarding.welcome.title'
      ]?.text,
    ).toBe('Willkommen zu Hause, {name}');
    expect(
      refreshed.translations.find((translation) => translation.locale === 'es')?.value?.entries[
        'settings.privacy.title'
      ]?.text,
    ).toBe('Privacidad');
    expect(await readFile(swiftPath, 'utf8')).toContain('"onboarding.welcome.title"');
    expect(await readFile(swiftPath, 'utf8')).not.toContain('tmp.WelcomeTitle');
    expect(await readFile(kotlinPath, 'utf8')).toContain('"settings.privacy.title"');

    expect(refreshed.history.value?.at(-1)).toMatchObject({
      files_updated: 2,
      op: 'lint_fix',
      renames: [
        {
          after: 'settings.privacy.title',
          before: 'settings.privacy-Title',
        },
        {
          after: 'onboarding.welcome.title',
          before: 'tmp.WelcomeTitle',
        },
      ],
    });

    const checkReport = await buildCheckReport(refreshed);
    expect(checkReport.ok).toBe(true);

    const lintFixEntryId = refreshed.history.value?.at(-1)?.id;
    expect(lintFixEntryId).toBeTruthy();

    await runRollback(refreshed, { to: lintFixEntryId! });

    const rolledBack = await loadProjectSnapshot(projectDir);
    expect(Object.keys(rolledBack.source.value.keys)).toEqual([
      'settings.privacy-Title',
      'tmp.WelcomeTitle',
    ]);
    expect(await readFile(swiftPath, 'utf8')).toContain('"tmp.WelcomeTitle"');
    expect(await readFile(kotlinPath, 'utf8')).toContain('"settings.privacy-Title"');
    expect(rolledBack.history.value?.at(-1)).toMatchObject({
      op: 'rollback',
      to: lintFixEntryId,
    });
  });

  it('fails cleanly when the provider cannot produce a safe rename plan', async () => {
    const projectDir = await createTempProject('lint-fix-skip');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, { description?: string; placeholders: Record<string, unknown>; text: string }>;
      version: number;
    };

    source.keys = {
      'tmp.WelcomeTitle': source.keys['onboarding.welcome.title']!,
      'settings.privacy.title': source.keys['settings.privacy.title']!,
    };
    await writeJson(sourcePath, source);

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = await runLintFix(snapshot, {
      provider: {
        planKeyRenames: async () => ({
          modelVersion: 'test-model',
          plans: [
            {
              from: 'tmp.WelcomeTitle',
              skip_reason: 'The destination scope is ambiguous with the current repository rules.',
            },
          ],
        }),
      },
    });

    expect(report.ok).toBe(false);
    expect(report.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: 'L10N_E0072',
          details: expect.objectContaining({
            key: 'tmp.WelcomeTitle',
          }),
        }),
      ]),
    );

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(Object.keys(refreshed.source.value.keys)).toEqual([
      'settings.privacy.title',
      'tmp.WelcomeTitle',
    ]);
  });

  it('plans lint autofixes in batches and reports progress', async () => {
    const projectDir = await createTempProject('lint-fix-batches');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const dePath = join(projectDir, 'l10n/translations.de.json');
    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, { description?: string; placeholders: Record<string, unknown>; text: string }>;
      version: number;
    };
    const de = JSON.parse(await readFile(dePath, 'utf8')) as {
      entries: Record<string, Record<string, unknown>>;
      locale: string;
      version: number;
    };

    source.keys = {
      'onboarding.navigation_title': {
        placeholders: {},
        text: 'Edit account',
      },
      'settings.navigation_title': {
        placeholders: {},
        text: 'Settings',
      },
      'settings.sync_now': {
        placeholders: {},
        text: 'Sync now',
      },
    };
    de.entries = {
      'onboarding.navigation_title': de.entries['onboarding.welcome.title']!,
      'settings.navigation_title': de.entries['settings.privacy.title']!,
      'settings.sync_now': de.entries['settings.privacy.title']!,
    };
    await writeJson(sourcePath, source);
    await writeJson(dePath, de);

    const snapshot = await loadProjectSnapshot(projectDir);
    const batches: string[][] = [];
    const progress: string[] = [];
    const report = await runLintFix(snapshot, {
      batchSize: 2,
      onProgress(update) {
        progress.push(update.message);
      },
      provider: {
        planKeyRenames: async (request) => {
          batches.push(request.candidates.map((candidate) => candidate.key));
          return {
            modelVersion: 'test-model',
            plans: request.candidates.map((candidate) => ({
              from: candidate.key,
              rationale: 'Split underscore titles into dotted segments.',
              skip_reason: null,
              to: candidate.key.replace(/_/g, '.'),
            })),
          };
        },
      },
    });

    expect(report.ok).toBe(true);
    expect(batches).toEqual([
      ['onboarding.navigation_title', 'settings.navigation_title'],
      ['settings.sync_now'],
    ]);
    expect(progress).toEqual(
      expect.arrayContaining([
        'Codex is planning key renames (1/2, 2 keys)',
        'Codex is planning key renames (2/2, 1 keys)',
        'Applying 3 key renames',
      ]),
    );
  });
});
