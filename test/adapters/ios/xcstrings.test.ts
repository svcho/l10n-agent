import { mkdtemp, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

import { describe, expect, it } from 'vitest';

import { IosXcstringsAdapter } from '../../../src/adapters/ios/xcstrings.js';
import { L10nError } from '../../../src/errors/l10n-error.js';

describe('IosXcstringsAdapter', () => {
  it.each([
    {
      fixture: 'fixtures/xcstrings/xcode-16.xcstrings',
      keyTransform: 'identity' as const,
      locales: ['de'],
    },
    {
      fixture: 'fixtures/xcstrings/xcode-17.xcstrings',
      keyTransform: 'snake_case' as const,
      locales: ['fr'],
    },
    {
      fixture: 'fixtures/xcstrings/xcode-18.xcstrings',
      keyTransform: 'identity' as const,
      locales: ['it'],
    },
  ])('round-trips $fixture without changing catalog JSON', async ({ fixture, keyTransform, locales }) => {
    const adapter = new IosXcstringsAdapter({
      keyTransform,
      sourceLocale: 'en',
    });
    const fixturePath = resolve(fixture);
    const workingDir = await mkdtemp(join(tmpdir(), 'l10n-agent-ios-'));
    const outputPath = join(workingDir, 'Localizable.xcstrings');

    const sourceKeys = await adapter.readWithComments(fixturePath, 'en');
    await adapter.write(outputPath, sourceKeys, 'en');

    for (const locale of locales) {
      await adapter.write(outputPath, await adapter.read(fixturePath, locale), locale);
    }

    expect(await readFile(outputPath, 'utf8')).toBe(await readFile(fixturePath, 'utf8'));
  });

  it('rejects plural entries in string catalogs', async () => {
    const adapter = new IosXcstringsAdapter({
      keyTransform: 'identity',
      sourceLocale: 'en',
    });

    await expect(adapter.read(resolve('fixtures/xcstrings/plural-unsupported.xcstrings'), 'en')).rejects.toMatchObject(
      {
        diagnostic: expect.objectContaining({
          code: 'L10N_E0042',
        }),
      } satisfies Partial<L10nError>,
    );
  });
});
