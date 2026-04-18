import { mkdtemp, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

import { describe, expect, it } from 'vitest';

import { IosStringsAdapter } from '../../../src/adapters/ios/strings.js';
import { L10nError } from '../../../src/errors/l10n-error.js';

describe('IosStringsAdapter', () => {
  it('round-trips Localizable.strings across locales', async () => {
    const adapter = new IosStringsAdapter({
      keyTransform: 'identity',
      sourceLocale: 'en',
    });
    const fixtureDir = resolve('fixtures/ios_strings/basic');
    const sourcePath = join(fixtureDir, 'en.lproj/Localizable.strings');
    const workingDir = await mkdtemp(join(tmpdir(), 'l10n-agent-ios-strings-'));
    const outputPath = join(workingDir, 'en.lproj/Localizable.strings');

    await adapter.write(outputPath, await adapter.readWithComments(sourcePath, 'en'), 'en');
    await adapter.write(outputPath, await adapter.read(sourcePath, 'de'), 'de');

    expect(await readFile(outputPath, 'utf8')).toBe(await readFile(sourcePath, 'utf8'));
    expect(await readFile(join(workingDir, 'de.lproj/Localizable.strings'), 'utf8')).toBe(
      await readFile(join(fixtureDir, 'de.lproj/Localizable.strings'), 'utf8'),
    );
  });

  it('rejects malformed Localizable.strings input', async () => {
    const adapter = new IosStringsAdapter({
      keyTransform: 'identity',
      sourceLocale: 'en',
    });

    await expect(adapter.read(resolve('fixtures/ios_strings/malformed.strings'), 'en')).rejects.toMatchObject({
      diagnostic: expect.objectContaining({
        code: 'L10N_E0031',
      }),
    } satisfies Partial<L10nError>);
  });
});
