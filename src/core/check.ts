import { access, constants } from 'node:fs/promises';

import {
  buildCanonicalKeySetFromSource,
  buildCanonicalKeySetFromTranslation,
  compareCanonicalKeySets,
} from '../adapters/canonical.js';
import { AndroidStringsAdapter } from '../adapters/android/strings.js';
import { createIosAdapter } from '../adapters/ios/index.js';
import { isIosStringsPath, resolveIosStringsLocalePath } from '../adapters/ios/strings.js';
import { L10nError } from '../errors/l10n-error.js';
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
  const iosAdapterOptions = snapshot.config.platforms.ios
    ? {
        sourceLocale: snapshot.config.source_locale,
        ...(snapshot.config.platforms.ios.key_transform
          ? { keyTransform: snapshot.config.platforms.ios.key_transform }
          : {}),
      }
    : null;
  const iosAdapter = snapshot.platformPaths.ios
    ? createIosAdapter(
        snapshot.platformPaths.ios,
        iosAdapterOptions ?? { sourceLocale: snapshot.config.source_locale },
      )
    : null;
  const androidAdapterOptions = snapshot.config.platforms.android
    ? {
        sourceLocale: snapshot.config.source_locale,
        ...(snapshot.config.platforms.android.key_transform
          ? { keyTransform: snapshot.config.platforms.android.key_transform }
          : {}),
      }
    : null;
  const androidAdapter = snapshot.platformPaths.android
    ? new AndroidStringsAdapter(androidAdapterOptions ?? { sourceLocale: snapshot.config.source_locale })
    : null;

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

  if (iosAdapter && snapshot.platformPaths.ios) {
    const iosSourcePath = isIosStringsPath(snapshot.platformPaths.ios)
      ? resolveIosStringsLocalePath(
          snapshot.platformPaths.ios,
          snapshot.config.source_locale,
          snapshot.config.source_locale,
        )
      : snapshot.platformPaths.ios;

    try {
      const sourceCatalog = await iosAdapter.read(snapshot.platformPaths.ios, snapshot.config.source_locale);
      diagnostics.push(
        ...compareCanonicalKeySets(buildCanonicalKeySetFromSource(snapshot.source.value), sourceCatalog, {
          locale: snapshot.config.source_locale,
          path: iosSourcePath,
          platform: 'ios',
        }),
      );

      for (const translation of snapshot.translations) {
        if (!translation.exists || !translation.value) {
          continue;
        }

        const iosLocalePath = isIosStringsPath(snapshot.platformPaths.ios)
          ? resolveIosStringsLocalePath(
              snapshot.platformPaths.ios,
              snapshot.config.source_locale,
              translation.locale,
            )
          : snapshot.platformPaths.ios;
        const localeCatalog = await iosAdapter.read(snapshot.platformPaths.ios, translation.locale);
        diagnostics.push(
          ...compareCanonicalKeySets(
            buildCanonicalKeySetFromTranslation(translation.value, snapshot.source.value),
            localeCatalog,
            {
              locale: translation.locale,
              path: iosLocalePath,
              platform: 'ios',
            },
          ),
        );
      }
    } catch (error) {
      if (error instanceof L10nError) {
        diagnostics.push(error.diagnostic);
      } else {
        throw error;
      }
    }
  }

  if (androidAdapter && snapshot.platformPaths.android) {
    try {
      const sourceResources = await androidAdapter.read(
        snapshot.platformPaths.android,
        snapshot.config.source_locale,
      );
      diagnostics.push(
        ...compareCanonicalKeySets(buildCanonicalKeySetFromSource(snapshot.source.value), sourceResources, {
          locale: snapshot.config.source_locale,
          path: snapshot.platformPaths.android,
          platform: 'android',
        }),
      );

      for (const translation of snapshot.translations) {
        if (!translation.exists || !translation.value) {
          continue;
        }

        const localeResources = await androidAdapter.read(snapshot.platformPaths.android, translation.locale);
        diagnostics.push(
          ...compareCanonicalKeySets(
            buildCanonicalKeySetFromTranslation(translation.value, snapshot.source.value),
            localeResources,
            {
              locale: translation.locale,
              path: snapshot.platformPaths.android,
              platform: 'android',
            },
          ),
        );
      }
    } catch (error) {
      if (error instanceof L10nError) {
        diagnostics.push(error.diagnostic);
      } else {
        throw error;
      }
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
