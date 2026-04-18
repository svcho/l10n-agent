import { describe, expect, it } from 'vitest';

import { buildDoctorReport } from '../../src/core/doctor.js';
import { loadProjectSnapshot } from '../../src/core/store/load.js';

describe('buildDoctorReport', () => {
  it('summarizes source, locale, and provider health', async () => {
    const snapshot = await loadProjectSnapshot('fixtures/projects/happy-path');
    const report = await buildDoctorReport(snapshot, async () => ({
      detectedVersion: '0.121.0',
      loginStatus: 'logged-in',
      meetsMinimumVersion: true,
      minimumVersion: '0.30.0',
    }));

    expect(report.source_keys).toBe(2);
    expect(report.cache_entries).toBe(1);
    expect(report.history_entries).toBe(1);
    expect(report.locales).toEqual([
      {
        locale: 'de',
        machine_translated: 1,
        missing: 0,
        orphaned: 0,
        reviewed: 1,
        stale: 0,
        total_entries: 2,
      },
      {
        locale: 'es',
        machine_translated: 2,
        missing: 0,
        orphaned: 0,
        reviewed: 0,
        stale: 0,
        total_entries: 2,
      },
    ]);
  });
});
