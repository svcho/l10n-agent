import { cp, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { lintGlossary } from '../../src/core/glossary.js';
import { loadProjectSnapshot } from '../../src/core/store/load.js';

async function createTempProject(name: string): Promise<string> {
  const targetDir = await mkdtemp(join(tmpdir(), `l10n-agent-${name}-`));
  await cp(resolve('fixtures/projects/happy-path'), targetDir, { recursive: true });
  return targetDir;
}

describe('lintGlossary', () => {
  it('flags translations that fail to preserve configured glossary terms', async () => {
    const projectDir = await createTempProject('glossary');
    const configPath = join(projectDir, 'l10n/config.yaml');
    const translationPath = join(projectDir, 'l10n/translations.de.json');

    await writeFile(
      configPath,
      `${await readFile(configPath, 'utf8')}  glossary:\n    Premium:\n      de: Premium\n`,
      'utf8',
    );

    const translation = JSON.parse(await readFile(translationPath, 'utf8')) as {
      entries: Record<string, { text: string }>;
      locale: string;
      version: number;
    };
    translation.entries['settings.privacy.title'].text = 'Datenschutz Plus';
    await writeFile(translationPath, JSON.stringify(translation, null, 2) + '\n', 'utf8');

    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, { description?: string; placeholders: Record<string, unknown>; text: string }>;
      version: number;
    };
    source.keys['settings.plan.title'] = {
      description: 'Plan picker headline.',
      placeholders: {},
      text: 'Premium plan',
    };
    await writeFile(sourcePath, JSON.stringify(source, null, 2) + '\n', 'utf8');

    const translationAfter = JSON.parse(await readFile(translationPath, 'utf8')) as {
      entries: Record<string, unknown>;
      locale: string;
      version: number;
    };
    translationAfter.entries['settings.plan.title'] = {
      model_version: 'manual',
      provider: 'human',
      reviewed: true,
      source_hash: 'sha256:fb734a9fde7135d5a0008f6ee4367382abf5ffb13ca6fb3f853f46da714121fa',
      stale: false,
      text: 'Plan Plus',
      translated_at: '2026-04-18T12:06:00Z',
    };
    await writeFile(translationPath, JSON.stringify(translationAfter, null, 2) + '\n', 'utf8');

    const snapshot = await loadProjectSnapshot(projectDir);
    const diagnostics = lintGlossary(snapshot);

    expect(diagnostics).toEqual([
      expect.objectContaining({
        code: 'L10N_E0087',
        details: expect.objectContaining({
          expected_term: 'Premium',
          key: 'settings.plan.title',
          locale: 'de',
          source_term: 'Premium',
        }),
      }),
    ]);
  });
});
