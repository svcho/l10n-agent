import { describe, expect, it } from 'vitest';

import { buildCheckReport } from '../../src/core/check.js';
import { loadProjectSnapshot } from '../../src/core/store/load.js';

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
});
