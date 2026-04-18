import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { buildCheckReport } from '../../src/core/check.js';
import { buildDedupeReport } from '../../src/core/dedupe.js';
import { runImport } from '../../src/core/import.js';
import { runInit } from '../../src/core/init.js';
import { runRename } from '../../src/core/rename.js';
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

describe('Milestone 5 flows', () => {
  it('flags exact duplicate source copy', async () => {
    const projectDir = await createTempProject('dedupe');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, { text: string; description?: string; placeholders: Record<string, unknown> }>;
      version: number;
    };

    source.keys['settings.privacy.label'] = {
      description: 'Intentional duplicate for dedupe detection.',
      placeholders: {},
      text: source.keys['settings.privacy.title']!.text,
    };
    await writeJson(sourcePath, source);

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = await buildDedupeReport(snapshot);

    expect(report.summary.exact_duplicate_groups).toBe(1);
    expect(report.exact_duplicates).toEqual([
      {
        keys: ['settings.privacy.label', 'settings.privacy.title'],
        text: 'Privacy',
      },
    ]);
  });

  it('flags semantic duplicate candidates from the provider without repeating exact matches', async () => {
    const projectDir = await createTempProject('semantic-dedupe');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, { text: string; description?: string; placeholders: Record<string, unknown> }>;
      version: number;
    };

    source.keys['button.save_item.title'] = {
      description: 'Save button for a single item detail screen.',
      placeholders: {},
      text: 'Save item',
    };
    source.keys['cta.save.label'] = {
      description: 'Primary save action.',
      placeholders: {},
      text: 'Save',
    };
    await writeJson(sourcePath, source);

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = await buildDedupeReport(snapshot, {
      findSemanticDuplicates: async () => ({
        groups: [
          {
            canonicalKey: 'missing.key',
            confidence: 0.95,
            duplicateKeys: ['settings.privacy.title'],
            rationale: 'bad result that should be ignored by consumers only if invalid keys existed',
          },
          {
            canonicalKey: 'cta.save.label',
            confidence: 0.78,
            duplicateKeys: ['button.save_item.title'],
            rationale: 'Both keys describe a primary save-style action label.',
          },
        ],
        modelVersion: 'codex-cli-test',
      }),
      id: 'test-provider',
      translate: async () => {
        throw new Error('not used');
      },
    });

    expect(report.semantic_duplicates).toEqual([
      {
        canonical_key: 'cta.save.label',
        confidence: 0.78,
        duplicate_keys: ['button.save_item.title'],
        model_version: 'codex-cli-test',
        rationale: 'Both keys describe a primary save-style action label.',
      },
    ]);
    expect(report.summary.semantic_duplicate_groups).toBe(1);
  });

  it('renames a canonical key across source, translations, platforms, and history', async () => {
    const projectDir = await createTempProject('rename');
    const snapshot = await loadProjectSnapshot(projectDir);

    const report = await runRename(snapshot, {
      from: 'onboarding.welcome.title',
      to: 'onboarding.hero.title',
    });

    expect(report.ok).toBe(true);

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(refreshed.source.value.keys['onboarding.welcome.title']).toBeUndefined();
    expect(refreshed.source.value.keys['onboarding.hero.title']?.text).toBe('Welcome home, {name}');
    expect(
      refreshed.translations.find((translation) => translation.locale === 'de')?.value?.entries[
        'onboarding.hero.title'
      ]?.text,
    ).toBe('Willkommen zu Hause, {name}');
    expect(
      refreshed.translations.find((translation) => translation.locale === 'de')?.value?.entries[
        'onboarding.welcome.title'
      ],
    ).toBeUndefined();
    expect(refreshed.history.value?.at(-1)).toMatchObject({
      after: 'onboarding.hero.title',
      before: 'onboarding.welcome.title',
      op: 'rename',
    });

    const checkReport = await buildCheckReport(refreshed);
    expect(checkReport.ok).toBe(true);
  });

  it('imports canonical source and translations from xcstrings', async () => {
    const projectDir = await createTempProject('import');
    await writeJson(join(projectDir, 'l10n/source.en.json'), { keys: {}, version: 1 });
    await writeJson(join(projectDir, 'l10n/translations.de.json'), { entries: {}, locale: 'de', version: 1 });
    await writeJson(join(projectDir, 'l10n/translations.es.json'), { entries: {}, locale: 'es', version: 1 });

    const snapshot = await loadProjectSnapshot(projectDir);
    const report = await runImport(snapshot, { from: 'xcstrings' });

    expect(report.ok).toBe(true);
    expect(report.summary.source_keys).toBe(2);

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(Object.keys(refreshed.source.value.keys)).toEqual([
      'onboarding.welcome.title',
      'settings.privacy.title',
    ]);
    expect(
      refreshed.translations.find((translation) => translation.locale === 'de')?.value?.entries[
        'settings.privacy.title'
      ],
    ).toMatchObject({
      provider: 'import:xcstrings',
      reviewed: true,
      text: 'Datenschutz',
    });
    expect(refreshed.history.value?.at(-1)).toMatchObject({
      from: 'xcstrings',
      op: 'import',
    });
  });

  it('rolls back tracked localization files to the snapshot before a history entry', async () => {
    const projectDir = await createTempProject('rollback');
    const beforeRename = await loadProjectSnapshot(projectDir);
    await runRename(beforeRename, {
      from: 'onboarding.welcome.title',
      to: 'onboarding.hero.title',
    });

    const afterRename = await loadProjectSnapshot(projectDir);
    const renameEntryId = afterRename.history.value?.at(-1)?.id;
    expect(renameEntryId).toBeTruthy();

    await runRollback(afterRename, { to: renameEntryId! });

    const refreshed = await loadProjectSnapshot(projectDir);
    expect(refreshed.source.value.keys['onboarding.welcome.title']?.text).toBe('Welcome home, {name}');
    expect(refreshed.source.value.keys['onboarding.hero.title']).toBeUndefined();
    expect(refreshed.history.value?.at(-1)).toMatchObject({
      op: 'rollback',
      to: renameEntryId,
    });
  });

  it('initializes a repo, detects platform files, and imports existing strings', async () => {
    const projectDir = await createTempProject('init');
    await rm(join(projectDir, 'l10n'), { force: true, recursive: true });

    const report = await runInit(projectDir, undefined, {
      sourceLocale: 'en',
      targetLocales: ['de', 'es'],
    });

    expect(report.ok).toBe(true);
    expect(report.imported_from).toBe('xcstrings');

    const snapshot = await loadProjectSnapshot(projectDir);
    expect(Object.keys(snapshot.source.value.keys)).toEqual([
      'onboarding.welcome.title',
      'settings.privacy.title',
    ]);
    expect(snapshot.history.value?.map((entry) => entry.op)).toEqual(['init', 'import']);
  });
});
