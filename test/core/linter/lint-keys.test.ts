import { describe, expect, it } from 'vitest';

import { loadProjectSnapshot } from '../../../src/core/store/load.js';
import { lintSourceKeys } from '../../../src/core/linter/lint-keys.js';

describe('lintSourceKeys', () => {
  it('returns all configured key-style violations', async () => {
    const snapshot = await loadProjectSnapshot('fixtures/projects/with-issues');
    const diagnostics = lintSourceKeys(snapshot.config, snapshot.source.value);

    expect(diagnostics.map((diagnostic) => diagnostic.code)).toEqual(
      expect.arrayContaining([
        'L10N_E0020',
        'L10N_E0021',
        'L10N_E0022',
        'L10N_E0023',
        'L10N_E0042',
      ]),
    );
  });
});
