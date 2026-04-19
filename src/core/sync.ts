import { access, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import process from 'node:process';

import { resolveAndroidLocalePath } from '../adapters/android/strings.js';
import { buildCanonicalKeySetFromSource, type ExtendedCanonicalKeySet } from '../adapters/canonical.js';
import { isIosStringsPath, resolveIosStringsLocalePath } from '../adapters/ios/strings.js';
import { L10nError } from '../errors/l10n-error.js';
import type { TranslationProvider, TranslationRequest } from '../providers/base.js';
import { readTextFile, writeJsonFileAtomic, writeTextFileAtomic } from '../utils/fs.js';
import type { SyncLockHandle } from '../utils/lock.js';
import { acquireSyncLock } from '../utils/lock.js';
import type { Diagnostic } from './diagnostics.js';
import { hasErrorDiagnostics } from './diagnostics.js';
import {
  buildHistoryId,
  createAddLocaleHistoryEntry,
  createRemoveLocaleHistoryEntry,
  createSyncHistoryEntry,
} from './history.js';
import { extractIcuPlaceholderMatches } from './placeholders/icu.js';
import { lintSourceKeys } from './linter/lint-keys.js';
import {
  getManagedFilePathsWithExtras,
  snapshotManagedFiles,
  writeProjectFiles,
  type TranslationLocaleState,
} from './project-files.js';
import type { ProjectSnapshot } from './store/load.js';
import type {
  CacheFile,
  SourceKey,
  SyncStateFile,
  TranslationEntry,
} from './store/schemas.js';
import {
  appendHistoryEntries,
  garbageCollectCache,
  removeFileIfExists,
  upsertCacheEntry,
  writeCacheFile,
  writeSyncState,
  writeTranslationFile,
} from './store/write.js';
import { computeConfigHash, computeProviderCacheKeyHash, computeSourceFileHash } from './store/hash.js';

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

export interface SyncProgress {
  completed: number;
  current_key?: string;
  current_locale?: string;
  message: string;
  total: number;
}

export interface SyncOptions {
  continueOnly?: boolean;
  dryRun?: boolean;
  locales?: string[];
  onProgress?: (progress: SyncProgress) => void;
  provider?: TranslationProvider;
  strict?: boolean;
}

interface MutableLocaleState extends TranslationLocaleState {
  dirty: boolean;
}

interface ActiveSyncContext {
  latestState: SyncStateFile | null;
  lock: SyncLockHandle;
  snapshot: ProjectSnapshot;
}

let activeSyncContext: ActiveSyncContext | null = null;

interface PlaceholderSignature {
  /** Placeholder names in extraction order. */
  ordered: string[];
  /** Frequency map — how many times each name appears. */
  counts: Map<string, number>;
  /** Sorted type signature string for each unique name. */
  types: string;
}

function buildPlaceholderSignature(source: SourceKey, text: string): PlaceholderSignature {
  const matches = extractIcuPlaceholderMatches(text);
  const ordered = matches.map((m) => m.name);

  const counts = new Map<string, number>();
  for (const name of ordered) {
    counts.set(name, (counts.get(name) ?? 0) + 1);
  }

  const typeLookup = new Map(
    Object.entries(source.placeholders).map(([name, placeholder]) => [name, placeholder.type]),
  );
  const types = [...counts.keys()]
    .sort()
    .map((name) => `${name}:${typeLookup.get(name) ?? 'string'}`)
    .join('|');

  return { counts, ordered, types };
}

function areMapsEqual(a: Map<string, number>, b: Map<string, number>): boolean {
  if (a.size !== b.size) {
    return false;
  }
  for (const [key, value] of a) {
    if (b.get(key) !== value) {
      return false;
    }
  }
  return true;
}

function hasPlaceholderParity(source: SourceKey, targetText: string): boolean {
  const sourceSig = buildPlaceholderSignature(source, source.text);
  const targetSig = buildPlaceholderSignature(source, targetText);

  // 1. Total placeholder count must match.
  if (sourceSig.ordered.length !== targetSig.ordered.length) {
    return false;
  }

  // 2. Multiset equality — each name must appear the same number of times.
  if (!areMapsEqual(sourceSig.counts, targetSig.counts)) {
    return false;
  }

  // 3. Type signature must match.
  if (sourceSig.types !== targetSig.types) {
    return false;
  }

  // 4. Positional ordering for digit-named placeholders ({0}, {1}, …).
  //    Named ICU placeholders like {count} or {user} may be reordered
  //    across languages for grammatical reasons, so we only enforce ordering
  //    for purely numeric names which are inherently positional.
  const sourcePositional = sourceSig.ordered.filter((name) => /^\d+$/u.test(name));
  const targetPositional = targetSig.ordered.filter((name) => /^\d+$/u.test(name));
  if (sourcePositional.join('|') !== targetPositional.join('|')) {
    return false;
  }

  return true;
}

function createInternalInvariantError(summary: string, details: Record<string, string> = {}): L10nError {
  return new L10nError({
    code: 'L10N_E0081',
    details,
    level: 'error',
    next: 'This should not happen in a healthy run. Capture the diagnostic details and inspect the surrounding sync state.',
    summary,
  });
}

function findCacheEntry(
  cache: CacheFile['entries'],
  sourceHash: string,
  locale: string,
  configHash: string,
): SyncTask['cacheHit'] {
  const matchingEntries = cache
    .filter(
      (entry) =>
        entry.source_hash === sourceHash &&
        entry.locale === locale &&
        entry.config_hash === configHash,
    )
    .map((entry) => ({
      cachedAt: entry.cached_at,
      modelVersion: entry.model_version,
      text: entry.text,
    }))
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
    throw createInternalInvariantError('Missing source key metadata while building a sync request', { key });
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

async function discoverRemovedTranslationFiles(
  snapshot: ProjectSnapshot,
  selectedLocales: string[],
): Promise<Array<{ locale: string; path: string }>> {
  const configuredLocales = new Set(selectedLocales);
  const entries = await readdir(snapshot.l10nDir, { withFileTypes: true }).catch(() => []);

  return entries
    .filter((entry) => entry.isFile())
    .flatMap((entry) => {
      const match = /^translations\.([a-z]{2}(?:-[A-Z]{2})?)\.json$/u.exec(entry.name);
      if (!match || !match[1]) {
        return [];
      }

      const locale = match[1];
      if (configuredLocales.has(locale)) {
        return [];
      }

      return [
        {
          locale,
          path: resolve(snapshot.l10nDir, entry.name),
        },
      ];
    })
    .sort((left, right) => left.locale.localeCompare(right.locale));
}

function buildArchivePath(l10nDir: string, locale: string, timestamp: string, suffix = ''): string {
  const safeTimestamp = timestamp.replaceAll(/[-:.TZ]/g, '').slice(0, 14);
  return resolve(l10nDir, '.archive', `translations.${locale}.${safeTimestamp}${suffix}.json`);
}

async function resolveUniqueArchivePath(l10nDir: string, locale: string, timestamp: string): Promise<string> {
  let attempt = 0;

  while (true) {
    const suffix = attempt === 0 ? '' : `-${attempt}`;
    const candidate = buildArchivePath(l10nDir, locale, timestamp, suffix);
    try {
      await access(candidate);
      attempt += 1;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        return candidate;
      }

      throw error;
    }
  }
}

async function archiveRemovedTranslations(
  l10nDir: string,
  removedTranslations: Array<{ locale: string; path: string }>,
  timestamp: string,
): Promise<void> {
  for (const translation of removedTranslations) {
    const rawText = await readTextFile(translation.path);
    await writeTextFileAtomic(await resolveUniqueArchivePath(l10nDir, translation.locale, timestamp), rawText);
    await removeFileIfExists(translation.path);
  }
}

export function buildSyncPlan(
  snapshot: ProjectSnapshot,
  options: Pick<SyncOptions, 'locales'> = {},
): SyncPlan {
  const selectedLocales = getSelectedLocales(snapshot, options.locales);
  const sourceKeys = Object.keys(snapshot.source.value.keys).sort();
  const sourceKeySet = new Set(sourceKeys);
  const canonicalSource = buildCanonicalKeySetFromSource(snapshot.source.value);
  const cacheEntries = snapshot.cache.value?.entries ?? [];
  const configHash = computeProviderCacheKeyHash(snapshot.config);
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
        const cacheHit = findCacheEntry(cacheEntries, sourceHash, locale, configHash);
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
        const cacheHit = findCacheEntry(cacheEntries, sourceHash, locale, configHash);
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

function buildOrphanedReviewedArchivePath(
  l10nDir: string,
  locale: string,
  timestamp: string,
  suffix = '',
): string {
  const safeTimestamp = timestamp.replaceAll(/[-:.TZ]/g, '').slice(0, 14);
  return resolve(l10nDir, '.snapshots', 'orphaned-reviewed', `${locale}-${safeTimestamp}${suffix}.json`);
}

async function resolveUniqueOrphanedReviewedArchivePath(
  l10nDir: string,
  locale: string,
  timestamp: string,
): Promise<string> {
  let attempt = 0;

  while (true) {
    const suffix = attempt === 0 ? '' : `-${attempt}`;
    const candidate = buildOrphanedReviewedArchivePath(l10nDir, locale, timestamp, suffix);
    try {
      await access(candidate);
      attempt += 1;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        return candidate;
      }

      throw error;
    }
  }
}

function createReviewedStaleWarning(key: string, locale: string): Diagnostic {
  return {
    code: 'L10N_E0090',
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

function createReviewedPlaceholderDivergenceDiagnostic(
  key: string,
  locale: string,
  source: string,
  target: string,
): Diagnostic {
  return {
    code: 'L10N_E0082',
    details: {
      key,
      locale,
      source,
      target,
    },
    level: 'error',
    next: 'Fix the reviewed translation manually so its placeholders match the current source, or clear reviewed=true before re-running sync.',
    summary: 'Reviewed translation no longer matches the current source placeholders',
  };
}

function createReviewedSourceKeyRemovedWarning(key: string, locale: string, archivePath: string): Diagnostic {
  return {
    code: 'L10N_E0083',
    details: { archive_path: archivePath, key, locale },
    level: 'warn',
    next: 'Review the archived translation and restore it manually if the key should still exist under a different canonical name.',
    summary: 'Reviewed translation was archived because its source key was removed',
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

function createSyncProgressMessage(
  task: Pick<SyncTask, 'cacheHit' | 'key' | 'locale'>,
  completed: number,
  total: number,
): string {
  const action = task.cacheHit ? 'Applying cached translation' : 'Translating';
  return `${action} (${completed}/${total}) ${task.locale} ${task.key}`;
}

function buildSyncState(
  snapshot: ProjectSnapshot,
  options: {
    completedTranslations: number;
    currentTask?: Pick<SyncTask, 'key' | 'locale'> | null;
    lastCompletedTask?: Pick<SyncTask, 'key' | 'locale'> | null;
    startedAt: string;
    status?: SyncStateFile['status'];
    totalTranslations: number;
  },
): SyncStateFile {
  const timestamp = new Date().toISOString();
  return {
    batch_index: options.completedTranslations,
    completed_translations: options.completedTranslations,
    config_hash: computeConfigHash(snapshot.config),
    pid: process.pid,
    source_hash: computeSourceFileHash(snapshot.source.value),
    started_at: options.startedAt,
    status: options.status ?? 'running',
    total_translations: options.totalTranslations,
    updated_at: timestamp,
    version: 1,
    ...(options.currentTask
      ? {
          current_key: options.currentTask.key,
          current_locale: options.currentTask.locale,
        }
      : {}),
    ...(options.lastCompletedTask
      ? {
          last_processed_key: options.lastCompletedTask.key,
          last_processed_locale: options.lastCompletedTask.locale,
        }
      : {}),
  };
}

async function persistSyncProgressState(
  snapshot: ProjectSnapshot,
  options: {
    completedTranslations: number;
    currentTask?: Pick<SyncTask, 'key' | 'locale'> | null;
    lastCompletedTask?: Pick<SyncTask, 'key' | 'locale'> | null;
    startedAt: string;
    totalTranslations: number;
  },
): Promise<void> {
  const state = buildSyncState(snapshot, options);
  await writeSyncState(snapshot.state.path, state);
  await activeSyncContext?.lock.refresh();
  if (activeSyncContext && activeSyncContext.snapshot.state.path === snapshot.state.path) {
    activeSyncContext.latestState = state;
  }
}

export async function interruptActiveSync(): Promise<boolean> {
  if (!activeSyncContext) {
    return false;
  }

  const state =
    activeSyncContext.latestState ??
    buildSyncState(activeSyncContext.snapshot, {
      completedTranslations: 0,
      startedAt: new Date().toISOString(),
      status: 'interrupted',
      totalTranslations: 0,
    });
  const interruptedState: SyncStateFile = {
    ...state,
    status: 'interrupted',
    updated_at: new Date().toISOString(),
  };

  await writeSyncState(activeSyncContext.snapshot.state.path, interruptedState);
  await activeSyncContext.lock.release();
  activeSyncContext.latestState = interruptedState;
  activeSyncContext = null;
  return true;
}

export async function runSync(
  snapshot: ProjectSnapshot,
  options: SyncOptions = {},
): Promise<SyncReport> {
  const diagnostics = [...snapshot.diagnostics, ...lintSourceKeys(snapshot.config, snapshot.source.value)];
  const selectedLocales = getSelectedLocales(snapshot, options.locales);
  const removedTranslationFiles = await discoverRemovedTranslationFiles(snapshot, selectedLocales);
  const addedLocales = snapshot.translations
    .filter((translation) => selectedLocales.includes(translation.locale) && !translation.exists)
    .map((translation) => translation.locale)
    .sort();
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

  const localeStates = new Map(selectedLocales.map((locale) => [locale, createMutableLocaleState(snapshot, locale)]));
  const orphanedReviewedArchives: Array<{
    entries: Record<string, TranslationEntry>;
    locale: string;
    path: string;
  }> = [];

  for (const localePlan of plan.locales) {
    const translationState = localeStates.get(localePlan.locale);
    if (!translationState) {
      continue;
    }

    for (const [key, existingEntry] of Object.entries(translationState.entries)) {
      if (!(key in snapshot.source.value.keys)) {
        continue;
      }

      const sourceKey = snapshot.source.value.keys[key];
      const expectedHash = snapshot.source.hashes.get(key);
      if (
        !sourceKey ||
        !existingEntry ||
        !expectedHash ||
        existingEntry.source_hash === expectedHash ||
        !existingEntry.reviewed
      ) {
        continue;
      }

      diagnostics.push(
        hasPlaceholderParity(sourceKey, existingEntry.text)
          ? createReviewedStaleWarning(key, localePlan.locale)
          : createReviewedPlaceholderDivergenceDiagnostic(
              key,
              localePlan.locale,
              sourceKey.text,
              existingEntry.text,
            ),
      );
    }

    const translation = snapshot.translations.find((candidate) => candidate.locale === localePlan.locale);
    const existingEntries = translation?.value?.entries ?? {};
    const orphanedReviewedEntries = Object.fromEntries(
      Object.entries(existingEntries).filter(
        ([key, entry]) => !(key in snapshot.source.value.keys) && entry.reviewed,
      ),
    );
    if (Object.keys(orphanedReviewedEntries).length > 0) {
      const archivePath = await resolveUniqueOrphanedReviewedArchivePath(
        snapshot.l10nDir,
        localePlan.locale,
        new Date().toISOString(),
      );
      diagnostics.push(
        ...Object.keys(orphanedReviewedEntries)
          .sort()
          .map((key) => createReviewedSourceKeyRemovedWarning(key, localePlan.locale, archivePath)),
      );

      orphanedReviewedArchives.push({
        entries: orphanedReviewedEntries,
        locale: localePlan.locale,
        path: archivePath,
      });
    }
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
    throw createInternalInvariantError('sync requires a translation provider');
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

  const cacheEntries = structuredClone(snapshot.cache.value?.entries ?? []);
  const configHash = computeProviderCacheKeyHash(snapshot.config);
  let completedTranslations = 0;
  let translated = 0;
  let cacheHits = 0;
  let lastCompletedTask: Pick<SyncTask, 'key' | 'locale'> | null = null;
  const startedAt = snapshot.state.value?.started_at ?? new Date().toISOString();
  const historyTimestamp = new Date().toISOString();
  const historyId = buildHistoryId(historyTimestamp, 'sync');
  const lock = await acquireSyncLock(snapshot.l10nDir);
  activeSyncContext = {
    latestState: buildSyncState(snapshot, {
      completedTranslations,
      lastCompletedTask,
      startedAt,
      totalTranslations: plan.total_pending_tasks,
    }),
    lock,
    snapshot,
  };

  try {
    await snapshotManagedFiles(
      snapshot.rootDir,
      snapshot.l10nDir,
      historyId,
      getManagedFilePathsWithExtras(snapshot, [
        ...removedTranslationFiles.map((translation) => translation.path),
        ...removedTranslationFiles.flatMap((translation) =>
          snapshot.platformPaths.android
            ? [resolveAndroidLocalePath(snapshot.platformPaths.android, snapshot.config.source_locale, translation.locale)]
            : [],
        ),
        ...removedTranslationFiles.flatMap((translation) =>
          snapshot.platformPaths.ios && isIosStringsPath(snapshot.platformPaths.ios)
            ? [resolveIosStringsLocalePath(snapshot.platformPaths.ios, snapshot.config.source_locale, translation.locale)]
            : [],
        ),
        ...orphanedReviewedArchives.map((archive) => archive.path),
      ]),
    );

    for (const archive of orphanedReviewedArchives) {
      await writeJsonFileAtomic(archive.path, {
        entries: archive.entries,
        locale: archive.locale,
        version: 1,
      });
    }

    options.onProgress?.({
      completed: completedTranslations,
      message:
        plan.total_pending_tasks > 0
          ? `Preparing sync for ${plan.total_pending_tasks} translations`
          : 'Writing derived translation and platform files',
      total: plan.total_pending_tasks,
    });
    await persistSyncProgressState(snapshot, {
      completedTranslations,
      lastCompletedTask,
      startedAt,
      totalTranslations: plan.total_pending_tasks,
    });

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
        const nextCompleted = completedTranslations + 1;
        options.onProgress?.({
          completed: completedTranslations,
          current_key: task.key,
          current_locale: task.locale,
          message: createSyncProgressMessage(task, nextCompleted, plan.total_pending_tasks),
          total: plan.total_pending_tasks,
        });
        await persistSyncProgressState(snapshot, {
          completedTranslations,
          currentTask: task,
          lastCompletedTask,
          startedAt,
          totalTranslations: plan.total_pending_tasks,
        });

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
          await persistSyncProgressState(snapshot, {
            completedTranslations,
            lastCompletedTask,
            startedAt,
            totalTranslations: plan.total_pending_tasks,
          });
          continue;
        }

        let result;
        try {
          result = await options.provider.translate(task.request);
        } catch (error) {
          if (
            error instanceof L10nError &&
            ['L10N_E0053', 'L10N_E0054', 'L10N_E0055', 'L10N_E0056'].includes(error.diagnostic.code)
          ) {
            const timestamp = new Date().toISOString();
            await persistSyncProgressState(snapshot, {
              completedTranslations,
              currentTask: task,
              lastCompletedTask,
              startedAt,
              totalTranslations: plan.total_pending_tasks,
            });
            await appendHistoryEntries(snapshot.history.path, [
              createSyncHistoryEntry(
                historyId,
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
          throw createInternalInvariantError('Missing source key metadata after a provider translation completed', {
            key: task.key,
            locale: task.locale,
          });
        }

        if (!hasPlaceholderParity(sourceKey, result.text)) {
          diagnostics.push(
            createPlaceholderDiagnostic(task.key, task.locale, task.request.sourceText, result.text),
          );

          if (options.strict) {
            await removeFileIfExists(snapshot.state.path);
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
        cacheEntries.splice(
          0,
          cacheEntries.length,
          ...upsertCacheEntry(cacheEntries, {
            cached_at: timestamp,
            config_hash: configHash,
            locale: task.locale,
            model_version: result.modelVersion,
            source_hash: task.sourceHash,
            text: result.text,
          }),
        );
        localeState.dirty = true;
        translated += 1;
        completedTranslations += 1;
        lastCompletedTask = {
          key: task.key,
          locale: task.locale,
        };

        await persistLocaleState(localeState);
        await writeCacheFile(snapshot.cache.path, cacheEntries);
        await persistSyncProgressState(snapshot, {
          completedTranslations,
          lastCompletedTask,
          startedAt,
          totalTranslations: plan.total_pending_tasks,
        });
      }

      await persistLocaleState(localeState);
    }

    for (const localeState of localeStates.values()) {
      await persistLocaleState(localeState);
    }

    options.onProgress?.({
      completed: completedTranslations,
      message: 'Writing derived translation and platform files',
      total: plan.total_pending_tasks,
    });

    const activeSourceHashes = new Set(snapshot.source.hashes.values());
    const gcedCacheEntries = garbageCollectCache(cacheEntries, activeSourceHashes);
    cacheEntries.splice(0, cacheEntries.length, ...gcedCacheEntries);

    await writeProjectFiles(snapshot, snapshot.source.value, [...localeStates.values()], {
      cacheEntries,
      removeState: true,
      removedLocales: removedTranslationFiles.map((translation) => translation.locale),
    });
    await archiveRemovedTranslations(snapshot.l10nDir, removedTranslationFiles, historyTimestamp);

    const timestamp = new Date().toISOString();
    await appendHistoryEntries(snapshot.history.path, [
      ...addedLocales.map((locale) =>
        createAddLocaleHistoryEntry(buildHistoryId(timestamp, `add-locale-${locale}`), timestamp, locale),
      ),
      ...removedTranslationFiles.map((translation) =>
        createRemoveLocaleHistoryEntry(
          buildHistoryId(timestamp, `remove-locale-${translation.locale}`),
          timestamp,
          translation.locale,
        ),
      ),
      createSyncHistoryEntry(
        historyId,
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
  } finally {
    if (activeSyncContext && activeSyncContext.snapshot.state.path === snapshot.state.path) {
      activeSyncContext = null;
    }
    await lock.release().catch(() => undefined);
  }
}
