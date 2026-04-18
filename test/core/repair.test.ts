import { cp, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { runRepair } from '../../src/core/repair.js';

async function createTempProject(name: string): Promise<string> {
  const targetDir = await mkdtemp(join(tmpdir(), `l10n-agent-${name}-`));
  await cp(resolve('fixtures/projects/happy-path'), targetDir, { recursive: true });
  return targetDir;
}

describe('runRepair', () => {
  it('reformats managed JSON files into canonical stable ordering', async () => {
    const projectDir = await createTempProject('repair-format');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    await writeFile(
      sourcePath,
      '{\n  "version": 1,\n  "keys": {\n    "settings.privacy.title": {"text":"Privacy","placeholders":{},"description":"Settings screen title."},\n    "onboarding.welcome.title": {"text":"Welcome home, {name}","placeholders":{"name":{"type":"string","example":"Jacob"}},"description":"First-launch hero. Friendly tone."}\n  }\n}\n',
      'utf8',
    );

    const report = await runRepair(projectDir);

    expect(report.ok).toBe(true);
    expect(report.summary.reformatted).toBeGreaterThanOrEqual(1);
    const repaired = await readFile(sourcePath, 'utf8');
    expect(repaired).toContain('"onboarding.welcome.title"');
    expect(repaired.indexOf('"onboarding.welcome.title"')).toBeLessThan(
      repaired.indexOf('"settings.privacy.title"'),
    );
  });

  it('auto-merges disjoint JSON conflict markers in managed files', async () => {
    const projectDir = await createTempProject('repair-conflict');
    const sourcePath = join(projectDir, 'l10n/source.en.json');
    await writeFile(
      sourcePath,
      `{
  "version": 1,
  "keys": {
<<<<<<< HEAD
    "settings.privacy.title": {
      "text": "Privacy",
      "description": "Settings screen title.",
      "placeholders": {}
    },
    "settings.notifications.title": {
      "text": "Notifications",
      "description": "Settings row title.",
      "placeholders": {}
    }
=======
    "onboarding.welcome.title": {
      "text": "Welcome home, {name}",
      "description": "First-launch hero. Friendly tone.",
      "placeholders": {
        "name": {
          "type": "string",
          "example": "Jacob"
        }
      }
    },
    "settings.privacy.title": {
      "text": "Privacy",
      "description": "Settings screen title.",
      "placeholders": {}
    }
>>>>>>> incoming
  }
}
`,
      'utf8',
    );

    const report = await runRepair(projectDir);

    expect(report.ok).toBe(true);
    expect(report.summary.auto_merged).toBe(1);

    const repaired = JSON.parse(await readFile(sourcePath, 'utf8')) as {
      keys: Record<string, unknown>;
      version: number;
    };
    expect(Object.keys(repaired.keys)).toEqual([
      'onboarding.welcome.title',
      'settings.notifications.title',
      'settings.privacy.title',
    ]);
  });
});
