import { userInfo } from 'node:os';

import {
  buildCanonicalKeySetFromSource,
  buildCanonicalKeySetFromTranslation,
  type ExtendedCanonicalKeySet,
} from '../adapters/canonical.js';
import { AndroidStringsAdapter } from '../adapters/android/strings.js';
import { IosXcstringsAdapter } from '../adapters/ios/xcstrings.js';
import { L10nError } from '../errors/l10n-error.js';
import type { TranslationProvider, TranslationRequest } from '../providers/base.js';
import type { Diagnostic } from './diagnostics.js';
import { hasErrorDiagnostics } from './diagnostics.js';
import { extractIcuPlaceholderNames } from './placeholders/icu.js';
import { lintSourceKeys } from './linter/lint-keys.js';
import type { ProjectSnapshot } from './store/load.js';
import type {
  CacheFile,
  HistoryEntry,
  SourceKey,
  SyncStateFile,
  TranslationEntry,
} from './store/schemas.js';
import {
  appendHistoryEntries,
  removeFileIfExists,
  writeCacheFile,
  writeSyncState,
  writeTranslationFile,
} from './store/write.js';

export interface SyncTask {
  cacheHit: {
    cachedAt: string;
    modelVersion: string;
    text: string;
  } | null;
  existingEntry: TranslationEntry | null;
  key: string;
  locale: string;
  reason: 'missing' | 'stale';
  request: TranslationRequest;
  sourceHash: string;
}

export interface LocaleSyncPlan {
  cache_hits: number;
  locale: string;
  missing: number;
  pending_tasks: SyncTask[];
  removed: number;
  reviewed_stale: number;
  stale_retranslations: number;
}

export interface SyncPlan {
  locales: LocaleSyncPlan[];
  platform_writes: {
    android: number;
    ios: number;
  };
  review_skips: number;
  source_keys: number;
  total_cache_hits: number;
  total_pending_tasks: number;
  total_removed: number;
}

export interface SyncReport {
  diagnostics: Diagnostic[];
  ok: boolean;
  resumed_from: {
    remaining_translations: number;
    started_at: string;
  } | null;
  summary: {
    cache_hits: number;
    locales: number;
    pending_tasks: number;
    provider_requests: number;
    removed: number;
    reviewed_skipped: number;
    source_keys: number;
    translated: number;
  };
}

export interface SyncOptions {
  continueOnly?: boolean;
  dryRun?: boolean;
  locales?: string[];
  provider?: TranslationProvider;
  strict?: boolean;
}

interface MutableLocaleState {
  dirty: boolean;
  entries: Record<string, TranslationEntry>;
  locale: string;
  path: string;
}

function getActor(): string {
  try {
    return userInfo().username;
  } catch {
    return process.env.USER ?? 'unknown';
  }
}

function buildHistoryId(timestamp: string, suffix: string): string {
  return `${timestamp.replaceAll(/[-:.TZ]/g, '').slice(0, 14)}-${suffix}`;
}

function createSyncHistoryEntry(timestamp: string, summary: string): HistoryEntry {
  return {
    actor: getActor(),
    id: buildHistoryId(timestamp, 'sync'),
    op: 'sync',
    summary,
    ts: timestamp,
  };
}

function buildPlaceholderSignature(source: SourceKey, text: string): { counts: string; types: string } {
  const names = extractIcuPlaceholderNames(text).sort();
  const counts = names.join('|');
  const typeLookup = new Map(
    Object.entries(source.placeholders).map(([name, placeholder]) => [name, placeholder.type]),
  );
  const typeSignature = [...new Set(names)]
    .sort()
    .map((name) => `${name}:${typeLookup.get(name) ?? 'string'}`)
    .join('|');

  return {
    counts,
    types: typeSignature,
  };
}

function hasPlaceholderParity(source: SourceKey, targetText: string): boolean {
  const sourceSignature = buildPlaceholderSignature(source, source.text);
  const targetSignature = buildPlaceholderSignature(source, targetText);
  return sourceSignature.counts === targetSignature.counts && sourceSignature.types === targetSignature.types;
}

function findCacheEntry(
  cache: CacheFile['entries'],
  sourceHash: string,
  locale: string,
): SyncTask['cacheHit'] {
  const matchingEntries = Object.entries(cache)
    .flatMap(([cacheKey, entry]) => {
      const [cachedHash, cachedLocale, ...modelParts] = cacheKey.split('|');
      const modelVersion = modelParts.join('|');

      if (cachedHash !== sourceHash || cachedLocale !== locale || modelVersion.length === 0) {
        return [];
      }

      return [
        {
          cachedAt: entry.cached_at,
          modelVersion,
          text: entry.text,
        },
      ];
    })
    .sort((left, right) => right.cachedAt.localeCompare(left.cachedAt));

  return matchingEntries[0] ?? null;
}

function validateRequestedLocales(snapshot: ProjectSnapshot, locales: string[]): void {
  const configuredLocales = new Set(snapshot.config.target_locales);
  for (const locale of locales) {
    if (!configuredLocales.has(locale)) {
      throw new L10nError({
        code: 'L10N_E0069',
        details: { locale },
        level: 'error',
        next: 'Choose a locale from target_locales in l10n/config.yaml.',
        summary: 'Requested sync locale is not configured',
      });
    }
  }
}

function getSelectedLocales(snapshot: ProjectSnapshot, locales?: string[]): string[] {
  if (!locales || locales.length === 0) {
    return [...snapshot.config.target_locales];
  }

  validateRequestedLocales(snapshot, locales);
  return [...new Set(locales)].sort();
}

function buildTranslationRequest(
  snapshot: ProjectSnapshot,
  key: string,
  locale: string,
  sourceValue: ExtendedCanonicalKeySet['keys'],
): TranslationRequest {
  const sourceKey = snapshot.source.value.keys[key];
  const canonicalValue = sourceValue.get(key);

  if (!sourceKey || !canonicalValue) {
    throw new Error(`Missing source key metadata for ${key}`);
  }

  return {
    glossary: snapshot.config.provider.glossary,
    placeholders: canonicalValue.placeholders,
    sourceLocale: snapshot.config.source_locale,
    sourceText: sourceKey.text,
    targetLocale: locale,
    ...(sourceKey.description ? { description: sourceKey.description } : {}),
  };
}

export function buildSyncPlan(
  snapshot: ProjectSnapshot,
  options: Pick<SyncOptions, 'locales'> = {},
): SyncPlan {
  const selectedLocales = getSelectedLocales(snapshot, options.locales);
  const sourceKeys = Object.keys(snapshot.source.value.keys).sort();
  const sourceKeySet = new Set(sourceKeys);
  const canonicalSource = buildCanonicalKeySetFromSource(snapshot.source.value);
  const cacheEntries = snapshot.cache.value?.entries ?? {};
  const translationByLocale = new Map(snapshot.translations.map((translation) => [translation.locale, translation]));

  const locales = selectedLocales.map((locale): LocaleSyncPlan => {
    const translation = translationByLocale.get(locale);
    const existingEntries = translation?.value?.entries ?? {};
    const removed = Object.keys(existingEntries).filter((key) => !sourceKeySet.has(key)).length;
    const pendingTasks: SyncTask[] = [];
    let missing = 0;
    let reviewedStale = 0;
    let staleRetranslations = 0;
    let cacheHits = 0;

    for (const key of sourceKeys) {
      const sourceHash = snapshot.source.hashes.get(key);
      const entry = existingEntries[key];
      if (!sourceHash) {
        continue;
      }

      if (!entry || entry.text.trim().length === 0) {
        missing += 1;
        const cacheHit = findCacheEntry(cacheEntries, sourceHash, locale);
        if (cacheHit) {
          cacheHits += 1;
        }

        pendingTasks.push({
          cacheHit,
          existingEntry: entry ?? null,
          key,
          locale,
          reason: 'missing',
          request: buildTranslationRequest(snapshot, key, locale, canonicalSource.keys),
          sourceHash,
        });
        continue;
      }

      if (entry.source_hash !== sourceHash) {
        if (entry.reviewed) {
          reviewedStale += 1;
          continue;
        }

        staleRetranslations += 1;
        const cacheHit = findCacheEntry(cacheEntries, sourceHash, locale);
        if (cacheHit) {
          cacheHits += 1;
        }

        pendingTasks.push({
          cacheHit,
          existingEntry: entry,
          key,
          locale,
          reason: 'stale',
          request: buildTranslationRequest(snapshot, key, locale, canonicalSource.keys),
          sourceHash,
        });
      }
    }

    return {
      cache_hits: cacheHits,
      locale,
      missing,
      pending_tasks: pendingTasks,
      removed,
      reviewed_stale: reviewedStale,
      stale_retranslations: staleRetranslations,
    };
  });

  const selectedLocaleCount = selectedLocales.length + 1;
  const sourceKeyCount = sourceKeys.length;

  return {
    locales,
    platform_writes: {
      android: snapshot.platformPaths.android ? sourceKeyCount * selectedLocaleCount : 0,
      ios: snapshot.platformPaths.ios ? sourceKeyCount * selectedLocaleCount : 0,
    },
    review_skips: locales.reduce((sum, locale) => sum + locale.reviewed_stale, 0),
    source_keys: sourceKeyCount,
    total_cache_hits: locales.reduce((sum, locale) => sum + locale.cache_hits, 0),
    total_pending_tasks: locales.reduce((sum, locale) => sum + locale.pending_tasks.length, 0),
    total_removed: locales.reduce((sum, locale) => sum + locale.removed, 0),
  };
}

function createMutableLocaleState(snapshot: ProjectSnapshot, locale: string): MutableLocaleState {
  const existingTranslation = snapshot.translations.find((translation) => translation.locale === locale);
  const sourceKeys = new Set(Object.keys(snapshot.source.value.keys));
  const entries = Object.fromEntries(
    Object.entries(existingTranslation?.value?.entries ?? {}).filter(([key]) => sourceKeys.has(key)),
  );

  return {
    dirty: Object.keys(entries).length !== Object.keys(existingTranslation?.value?.entries ?? {}).length,
    entries,
    locale,
    path: existingTranslation?.path ?? `${snapshot.l10nDir}/translations.${locale}.json`,
  };
}

function createReviewedStaleWarning(key: string, locale: string): Diagnostic {
  return {
    code: 'L10N_E0064',
    details: { key, locale },
    level: 'warn',
    next: 'Edit the translation manually or clear reviewed=true before re-running sync.',
    summary: 'Reviewed translation was left stale because sync does not overwrite human-reviewed entries',
  };
}

function createPlaceholderDiagnostic(key: string, locale: string, source: string, target: string): Diagnostic {
  return {
    code: 'L10N_E0041',
    details: {
      key,
      locale,
      source,
      target,
    },
    level: 'error',
    next: 'Re-run sync for the key or fix the translation manually while preserving placeholders.',
    summary: 'Placeholder mismatch in translation',
  };
}

async function persistLocaleState(
  localeState: MutableLocaleState,
): Promise<void> {
  if (!localeState.dirty) {
    return;
  }

  await writeTranslationFile(localeState.path, localeState.locale, localeState.entries);
  localeState.dirty = false;
}

async function writePlatforms(
  snapshot: ProjectSnapshot,
  localeStates: Map<string, MutableLocaleState>,
  selectedLocales: string[],
): Promise<void> {
  const sourceCanonical = buildCanonicalKeySetFromSource(snapshot.source.value);
  const selectedLocaleSet = new Set(selectedLocales);

  if (snapshot.platformPaths.ios && snapshot.config.platforms.ios) {
    const adapter = new IosXcstringsAdapter({
      keyTransform: snapshot.config.platforms.ios.key_transform,
      sourceLocale: snapshot.config.source_locale,
    });

    await adapter.write(snapshot.platformPaths.ios, sourceCanonical, snapshot.config.source_locale);

    for (const translation of snapshot.translations) {
      if (!selectedLocaleSet.has(translation.locale)) {
        continue;
      }

      const localeState = localeStates.get(translation.locale);
      if (!localeState) {
        continue;
      }

      await adapter.write(
        snapshot.platformPaths.ios,
        buildCanonicalKeySetFromTranslation(
          {
            entries: localeState.entries,
            locale: translation.locale,
            version: 1,
          },
          snapshot.source.value,
        ),
        translation.locale,
      );
    }
  }

  if (snapshot.platformPaths.android && snapshot.config.platforms.android) {
    const adapter = new AndroidStringsAdapter({
      keyTransform: snapshot.config.platforms.android.key_transform,
      sourceLocale: snapshot.config.source_locale,
    });

    await adapter.write(snapshot.platformPaths.android, sourceCanonical, snapshot.config.source_locale);

    for (const translation of snapshot.translations) {
      if (!selectedLocaleSet.has(translation.locale)) {
        continue;
      }

      const localeState = localeStates.get(translation.locale);
      if (!localeState) {
        continue;
      }

      await adapter.write(
        snapshot.platformPaths.android,
        buildCanonicalKeySetFromTranslation(
          {
            entries: localeState.entries,
            locale: translation.locale,
            version: 1,
          },
          snapshot.source.value,
        ),
        translation.locale,
      );
    }
  }
}

export async function runSync(
  snapshot: ProjectSnapshot,
  options: SyncOptions = {},
): Promise<SyncReport> {
  const diagnostics = lintSourceKeys(snapshot.config, snapshot.source.value);
  const selectedLocales = getSelectedLocales(snapshot, options.locales);
  const plan = buildSyncPlan(snapshot, { locales: selectedLocales });
  const resumedFrom =
    snapshot.state.exists && snapshot.state.value && plan.total_pending_tasks > 0
      ? {
          remaining_translations: plan.total_pending_tasks,
          started_at: snapshot.state.value.started_at,
        }
      : null;

  if (options.continueOnly && !snapshot.state.exists) {
    throw new L10nError({
      code: 'L10N_E0069',
      details: { path: snapshot.state.path },
      level: 'error',
      next: 'Re-run sync without --continue, or resume after a partial provider failure creates .state.json.',
      summary: 'No partial sync state exists to continue from',
    });
  }

  if (hasErrorDiagnostics(diagnostics)) {
    return {
      diagnostics,
      ok: false,
      resumed_from: resumedFrom,
      summary: {
        cache_hits: plan.total_cache_hits,
        locales: selectedLocales.length,
        pending_tasks: plan.total_pending_tasks,
        provider_requests: plan.total_pending_tasks - plan.total_cache_hits,
        removed: plan.total_removed,
        reviewed_skipped: plan.review_skips,
        source_keys: plan.source_keys,
        translated: 0,
      },
    };
  }

  for (const localePlan of plan.locales) {
    const translation = snapshot.translations.find((candidate) => candidate.locale === localePlan.locale);
    const existingEntries = translation?.value?.entries ?? {};

    for (const key of Object.keys(existingEntries)) {
      if (!(key in snapshot.source.value.keys)) {
        continue;
      }

      const existingEntry = existingEntries[key];
      const expectedHash = snapshot.source.hashes.get(key);
      if (!existingEntry || !expectedHash || existingEntry.source_hash === expectedHash || !existingEntry.reviewed) {
        continue;
      }

      diagnostics.push(createReviewedStaleWarning(key, localePlan.locale));
    }
  }

  if (options.dryRun) {
    return {
      diagnostics,
      ok: !hasErrorDiagnostics(diagnostics),
      resumed_from: resumedFrom,
      summary: {
        cache_hits: plan.total_cache_hits,
        locales: selectedLocales.length,
        pending_tasks: plan.total_pending_tasks,
        provider_requests: plan.total_pending_tasks - plan.total_cache_hits,
        removed: plan.total_removed,
        reviewed_skipped: plan.review_skips,
        source_keys: plan.source_keys,
        translated: 0,
      },
    };
  }

  if (!options.provider) {
    throw new Error('sync requires a translation provider');
  }

  const preflight = options.provider.preflight ? await options.provider.preflight() : { ok: true };
  if (!preflight.ok) {
    throw new L10nError({
      code: preflight.code ?? 'L10N_E0054',
      details: preflight.detectedVersion ? { detected_version: preflight.detectedVersion } : {},
      level: 'error',
      next: preflight.message ?? 'Re-run the command after fixing the provider environment.',
      summary: 'Provider preflight failed',
    });
  }

  const localeStates = new Map(selectedLocales.map((locale) => [locale, createMutableLocaleState(snapshot, locale)]));
  const cacheEntries = structuredClone(snapshot.cache.value?.entries ?? {});
  let completedTranslations = 0;
  let translated = 0;
  let cacheHits = 0;
  let lastCompletedTask: Pick<SyncTask, 'key' | 'locale'> | null = null;
  const historyEntries = [...(snapshot.history.value ?? [])];

  for (const localePlan of plan.locales) {
    const localeState = localeStates.get(localePlan.locale);
    if (!localeState) {
      continue;
    }

    for (const [key, entry] of Object.entries(localeState.entries)) {
      const expectedHash = snapshot.source.hashes.get(key);
      if (expectedHash && entry.reviewed && entry.source_hash !== expectedHash && !entry.stale) {
        localeState.entries[key] = {
          ...entry,
          stale: true,
        };
        localeState.dirty = true;
      } else if (expectedHash && entry.source_hash === expectedHash && entry.stale) {
        localeState.entries[key] = {
          ...entry,
          stale: false,
        };
        localeState.dirty = true;
      }
    }

    for (const task of localePlan.pending_tasks) {
      if (task.cacheHit) {
        localeState.entries[task.key] = {
          model_version: task.cacheHit.modelVersion,
          provider: options.provider.id,
          reviewed: false,
          source_hash: task.sourceHash,
          stale: false,
          text: task.cacheHit.text,
          translated_at: task.cacheHit.cachedAt,
        };
        localeState.dirty = true;
        cacheHits += 1;
        completedTranslations += 1;
        lastCompletedTask = {
          key: task.key,
          locale: task.locale,
        };
        await persistLocaleState(localeState);
        continue;
      }

      let result;
      try {
        result = await options.provider.translate(task.request);
      } catch (error) {
        if (error instanceof L10nError && ['L10N_E0053', 'L10N_E0054', 'L10N_E0055'].includes(error.diagnostic.code)) {
          const timestamp = new Date().toISOString();
          const state: SyncStateFile = {
            batch_index: completedTranslations,
            completed_translations: completedTranslations,
            started_at: snapshot.state.value?.started_at ?? timestamp,
            total_translations: plan.total_pending_tasks,
            updated_at: timestamp,
            version: 1,
            ...(lastCompletedTask
              ? {
                  last_processed_key: lastCompletedTask.key,
                  last_processed_locale: lastCompletedTask.locale,
                }
              : {}),
          };

          await writeSyncState(snapshot.state.path, state);
          await appendHistoryEntries(snapshot.history.path, historyEntries, [
            createSyncHistoryEntry(
              timestamp,
              `${completedTranslations} of ${plan.total_pending_tasks} translations completed before ${error.diagnostic.code}`,
            ),
          ]);

          throw error;
        }

        throw error;
      }

      const sourceKey = snapshot.source.value.keys[task.key];
      if (!sourceKey) {
        continue;
      }

      if (!hasPlaceholderParity(sourceKey, result.text)) {
        diagnostics.push(
          createPlaceholderDiagnostic(task.key, task.locale, task.request.sourceText, result.text),
        );

        if (options.strict) {
          return {
            diagnostics,
            ok: false,
            resumed_from: resumedFrom,
            summary: {
              cache_hits: cacheHits,
              locales: selectedLocales.length,
              pending_tasks: plan.total_pending_tasks,
              provider_requests: plan.total_pending_tasks - plan.total_cache_hits,
              removed: plan.total_removed,
              reviewed_skipped: plan.review_skips,
              source_keys: plan.source_keys,
              translated,
            },
          };
        }

        continue;
      }

      const timestamp = new Date().toISOString();
      localeState.entries[task.key] = {
        model_version: result.modelVersion,
        provider: options.provider.id,
        reviewed: false,
        source_hash: task.sourceHash,
        stale: false,
        text: result.text,
        translated_at: timestamp,
      };
      cacheEntries[`${task.sourceHash}|${task.locale}|${result.modelVersion}`] = {
        cached_at: timestamp,
        text: result.text,
      };
      localeState.dirty = true;
      translated += 1;
      completedTranslations += 1;
      lastCompletedTask = {
        key: task.key,
        locale: task.locale,
      };

      await persistLocaleState(localeState);
      await writeCacheFile(snapshot.cache.path, cacheEntries);
    }

    await persistLocaleState(localeState);
  }

  for (const localeState of localeStates.values()) {
    await persistLocaleState(localeState);
  }

  await writeCacheFile(snapshot.cache.path, cacheEntries);
  await writePlatforms(snapshot, localeStates, selectedLocales);
  await removeFileIfExists(snapshot.state.path);

  const timestamp = new Date().toISOString();
  await appendHistoryEntries(snapshot.history.path, historyEntries, [
    createSyncHistoryEntry(
      timestamp,
      `${translated} translations generated, ${cacheHits} cache hits, ${plan.review_skips} reviewed skipped, ${plan.total_removed} removed`,
    ),
  ]);

  return {
    diagnostics,
    ok: !hasErrorDiagnostics(diagnostics),
    resumed_from: resumedFrom,
    summary: {
      cache_hits: cacheHits,
      locales: selectedLocales.length,
      pending_tasks: plan.total_pending_tasks,
      provider_requests: plan.total_pending_tasks - plan.total_cache_hits,
      removed: plan.total_removed,
      reviewed_skipped: plan.review_skips,
      source_keys: plan.source_keys,
      translated,
    },
  };
}
