import { describe, expect, it } from 'vitest';

import { loadConfig } from '../../src/config/load.js';

describe('loadConfig', () => {
  it('loads a valid project config', async () => {
    const loaded = await loadConfig('fixtures/projects/happy-path');

    expect(loaded.config.source_locale).toBe('en');
    expect(loaded.config.target_locales).toEqual(['de', 'es']);
    expect(loaded.config.platforms.ios?.path).toBe('ios/MyApp/Localizable.xcstrings');
  });
});
