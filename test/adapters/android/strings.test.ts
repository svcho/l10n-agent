import { mkdtemp, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

import { describe, expect, it } from 'vitest';

import { AndroidStringsAdapter } from '../../../src/adapters/android/strings.js';
import { L10nError } from '../../../src/errors/l10n-error.js';

describe('AndroidStringsAdapter', () => {
  it.each([
    {
      fixture: 'fixtures/strings_xml/basic/values/strings.xml',
      keyTransform: 'snake_case' as const,
      locales: ['de'],
    },
    {
      fixture: 'fixtures/strings_xml/region/values/strings.xml',
      keyTransform: 'snake_case' as const,
      locales: ['pt-BR'],
    },
  ])('round-trips $fixture without changing strings.xml output', async ({ fixture, keyTransform, locales }) => {
    const adapter = new AndroidStringsAdapter({
      keyTransform,
      sourceLocale: 'en',
    });
    const fixturePath = resolve(fixture);
    const workingDir = await mkdtemp(join(tmpdir(), 'l10n-agent-android-'));
    const outputPath = join(workingDir, 'res/values/strings.xml');

    await adapter.write(outputPath, await adapter.read(fixturePath, 'en'), 'en');

    for (const locale of locales) {
      await adapter.write(outputPath, await adapter.read(fixturePath, locale), locale);
    }

    expect(await readFile(outputPath, 'utf8')).toBe(await readFile(fixturePath, 'utf8'));

    for (const locale of locales) {
      const expectedLocalePath =
        locale === 'de'
          ? resolve('fixtures/strings_xml/basic/values-de/strings.xml')
          : resolve('fixtures/strings_xml/region/values-pt-rBR/strings.xml');
      const outputLocalePath =
        locale === 'de'
          ? join(workingDir, 'res/values-de/strings.xml')
          : join(workingDir, 'res/values-pt-rBR/strings.xml');

      expect(await readFile(outputLocalePath, 'utf8')).toBe(await readFile(expectedLocalePath, 'utf8'));
    }
  });

  it('rejects plural resources', async () => {
    const adapter = new AndroidStringsAdapter({
      keyTransform: 'snake_case',
      sourceLocale: 'en',
    });

    await expect(adapter.read(resolve('fixtures/strings_xml/plural-unsupported.xml'), 'en')).rejects.toMatchObject({
      diagnostic: expect.objectContaining({
        code: 'L10N_E0042',
      }),
    } satisfies Partial<L10nError>);
  });
});
