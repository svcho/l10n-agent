import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { loadConfig } from '../../src/config/load.js';

describe('loadConfig', () => {
  it('loads a valid project config', async () => {
    const loaded = await loadConfig('fixtures/projects/happy-path');

    expect(loaded.config.source_locale).toBe('en');
    expect(loaded.config.target_locales).toEqual(['de', 'es']);
    expect(loaded.config.platforms.ios?.path).toBe('ios/MyApp/Localizable.xcstrings');
  });

  it('loads an explicit provider model override', async () => {
    const projectDir = await mkdtemp(join(tmpdir(), 'l10n-agent-config-'));
    await mkdir(join(projectDir, 'l10n'), { recursive: true });
    await writeFile(
      join(projectDir, 'l10n/config.yaml'),
      [
        'version: 1',
        'source_locale: en',
        'target_locales:',
        '  - de',
        'keys:',
        '  case: dotted.lower',
        '  max_depth: 4',
        '  scopes: []',
        '  forbidden_prefixes: []',
        'platforms:',
        '  ios:',
        '    path: ios/MyApp/Localizable.xcstrings',
        '    key_transform: identity',
        'provider:',
        '  type: codex-local',
        '  codex_min_version: 0.30.0',
        '  model: gpt-5.1',
        '  glossary: {}',
        '',
      ].join('\n'),
      'utf8',
    );

    const loaded = await loadConfig(projectDir);

    expect(loaded.config.provider.model).toBe('gpt-5.1');
  });
});
