import { access, constants } from 'node:fs/promises';

import type { Diagnostic } from './diagnostics.js';
import { compareDiagnostics, hasErrorDiagnostics } from './diagnostics.js';
import { lintSourceKeys } from './linter/lint-keys.js';
import type { ProjectSnapshot } from './store/load.js';

export interface CheckReport {
  diagnostics: Diagnostic[];
  ok: boolean;
  summary: {
    locales_checked: number;
    source_keys: number;
  };
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

export async function buildCheckReport(snapshot: ProjectSnapshot): Promise<CheckReport> {
  const diagnostics: Diagnostic[] = [];
  const sourceKeys = Object.keys(snapshot.source.value.keys);
  const sourceKeySet = new Set(sourceKeys);

  diagnostics.push(...lintSourceKeys(snapshot.config, snapshot.source.value));

  for (const [platform, platformPath] of Object.entries(snapshot.platformPaths) as Array<
    ['ios' | 'android', string | null]
  >) {
    if (!platformPath) {
      continue;
    }

    if (!(await pathExists(platformPath))) {
      diagnostics.push({
        code: 'L10N_E0030',
        details: { path: platformPath, platform },
        level: 'error',
        next: 'Create the configured platform file or fix the path in l10n/config.yaml.',
        summary: 'Configured platform path does not exist',
      });
    }
  }

  for (const translation of snapshot.translations) {
    if (!translation.exists || !translation.value) {
      diagnostics.push({
        code: 'L10N_E0061',
        details: { locale: translation.locale, path: translation.path },
        level: 'error',
        next: 'Create the translation file or run the future sync workflow once it exists.',
        summary: 'Translation file is missing',
      });
      continue;
    }

    for (const key of sourceKeys) {
      const entry = translation.value.entries[key];
      if (!entry || entry.text.trim().length === 0) {
        diagnostics.push({
          code: 'L10N_E0063',
          details: { key, locale: translation.locale },
          level: 'error',
          next: 'Add a translation entry for the missing key.',
          summary: 'Locale is missing a translation entry',
        });
        continue;
      }

      const expectedSourceHash = snapshot.source.hashes.get(key);
      if (expectedSourceHash && entry.source_hash !== expectedSourceHash) {
        diagnostics.push({
          code: 'L10N_E0064',
          details: {
            key,
            locale: translation.locale,
            expected_source_hash: expectedSourceHash,
            actual_source_hash: entry.source_hash,
          },
          level: 'error',
          next: 'Refresh the translation so its source hash matches the canonical source.',
          summary: 'Translation entry is stale relative to source',
        });
      }
    }

    for (const orphanedKey of Object.keys(translation.value.entries)) {
      if (!sourceKeySet.has(orphanedKey)) {
        diagnostics.push({
          code: 'L10N_E0065',
          details: { key: orphanedKey, locale: translation.locale },
          level: 'error',
          next: 'Remove the orphaned key from the translation file or restore it in the source file.',
          summary: 'Translation file contains a key missing from source',
        });
      }
    }
  }

  diagnostics.sort(compareDiagnostics);

  return {
    diagnostics,
    ok: !hasErrorDiagnostics(diagnostics),
    summary: {
      locales_checked: snapshot.translations.length,
      source_keys: sourceKeys.length,
    },
  };
}
