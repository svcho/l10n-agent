import { cp, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { buildCheckReport } from '../../src/core/check.js';
import { computeSourceHash } from '../../src/core/store/hash.js';
import { loadProjectSnapshot } from '../../src/core/store/load.js';
import { stableStringify } from '../../src/utils/json.js';

async function createTempProject(name: string): Promise<string> {
  const targetDir = await mkdtemp(join(tmpdir(), `l10n-agent-check-${name}-`));
  await cp(resolve('fixtures/projects/happy-path'), targetDir, { recursive: true });
  return targetDir;
}

describe('buildCheckReport', () => {
  it('passes the healthy fixture repo', async () => {
    const snapshot = await loadProjectSnapshot('fixtures/projects/happy-path');
    const report = await buildCheckReport(snapshot);

    expect(report.ok).toBe(true);
    expect(report.diagnostics).toHaveLength(0);
  });

  it('reports missing, stale, orphaned, lint, and platform issues', async () => {
    const snapshot = await loadProjectSnapshot('fixtures/projects/with-issues');
    const report = await buildCheckReport(snapshot);
    const codes = report.diagnostics.map((diagnostic) => diagnostic.code);

    expect(report.ok).toBe(false);
    expect(codes).toEqual(
      expect.arrayContaining([
        'L10N_E0020',
        'L10N_E0021',
        'L10N_E0022',
        'L10N_E0023',
        'L10N_E0030',
        'L10N_E0042',
        'L10N_E0061',
        'L10N_E0063',
        'L10N_E0064',
        'L10N_E0065',
      ]),
    );
  });

  it('reports translation placeholder mismatches even when the source hash matches', async () => {
    const projectDir = await createTempProject('placeholder-mismatch');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    const translationPath = join(projectDir, 'l10n/translations.de.json');
    const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, { description?: string; placeholders: Record<string, { type: 'string' }>; text: string }>;
      version: number;
    };
    const translation = JSON.parse(await readFile(translationPath, 'utf8')) as {
      entries: Record<string, { source_hash: string; text: string }>;
      locale: string;
      version: number;
    };

    const key = 'onboarding.welcome.title';
    const sourceKey = source.keys[key]!;
    translation.entries[key] = {
      ...translation.entries[key]!,
      source_hash: computeSourceHash(sourceKey),
      text: 'Willkommen zu Hause',
    };
    await writeFile(translationPath, stableStringify(translation), 'utf8');

    const report = await buildCheckReport(await loadProjectSnapshot(projectDir));

    expect(report.ok).toBe(false);
    expect(report.diagnostics).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          code: 'L10N_E0041',
          details: expect.objectContaining({ key, locale: 'de' }),
        }),
      ]),
    );
  });
});
