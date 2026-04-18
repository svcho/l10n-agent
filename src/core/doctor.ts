import { AndroidStringsAdapter } from '../adapters/android/strings.js';
import { createIosAdapter } from '../adapters/ios/index.js';
import type { TranslationRequest } from '../providers/base.js';
import type { CodexPreflightResult } from '../providers/codex-local.js';
import type { Diagnostic } from './diagnostics.js';
import { buildSyncPlan } from './sync.js';
import type { ProjectSnapshot } from './store/load.js';

export interface DoctorLocaleReport {
  locale: string;
  machine_translated: number;
  missing: number;
  orphaned: number;
  reviewed: number;
  stale: number;
  total_entries: number;
}

export interface DoctorReport {
  cache_entries: number;
  codex: CodexPreflightResult;
  diagnostics: Diagnostic[];
  estimated_requests: {
    notes: string | null;
    requests: number | null;
  };
  history_entries: number;
  last_history_at: string | null;
  locales: DoctorLocaleReport[];
  platforms: Array<{
    configured: boolean;
    key_count: number | null;
    locales: string[];
    path: string | null;
    platform: 'ios' | 'android';
    version: string | null;
  }>;
  source_keys: number;
}

export async function buildDoctorReport(
  snapshot: ProjectSnapshot,
  preflight: () => Promise<CodexPreflightResult>,
  estimateRequests?: (
    inputs: TranslationRequest[],
  ) => Promise<{ notes?: string; requests: number }>,
): Promise<DoctorReport> {
  const sourceKeys = Object.keys(snapshot.source.value.keys);
  const sourceKeySet = new Set(sourceKeys);
  const plan = buildSyncPlan(snapshot);
  const codex = await preflight();
  const pendingInputs = plan.locales.flatMap((locale) =>
    locale.pending_tasks.filter((task) => task.cacheHit === null).map((task) => task.request),
  );
  const estimatedRequests =
    estimateRequests && codex.loginStatus === 'logged-in' && codex.meetsMinimumVersion
      ? await estimateRequests(pendingInputs)
      : null;

  const locales = snapshot.translations.map((translation): DoctorLocaleReport => {
    if (!translation.exists || !translation.value) {
      return {
        locale: translation.locale,
        machine_translated: 0,
        missing: sourceKeys.length,
        orphaned: 0,
        reviewed: 0,
        stale: 0,
        total_entries: 0,
      };
    }

    let reviewed = 0;
    let machineTranslated = 0;
    let stale = 0;
    let orphaned = 0;
    let matchingEntries = 0;

    for (const [key, entry] of Object.entries(translation.value.entries)) {
      if (!sourceKeySet.has(key)) {
        orphaned += 1;
        continue;
      }

      matchingEntries += 1;
      if (entry.reviewed) {
        reviewed += 1;
      } else {
        machineTranslated += 1;
      }

      const expectedHash = snapshot.source.hashes.get(key);
      if (expectedHash && entry.source_hash !== expectedHash) {
        stale += 1;
      }
    }

    return {
      locale: translation.locale,
      machine_translated: machineTranslated,
      missing: sourceKeys.length - matchingEntries,
      orphaned,
      reviewed,
      stale,
      total_entries: Object.keys(translation.value.entries).length,
    };
  });

  const historyEntries = snapshot.history.value ?? [];
  const lastHistoryAt = historyEntries.length > 0 ? historyEntries[historyEntries.length - 1]?.ts ?? null : null;

  const iosPlatformReport =
    snapshot.platformPaths.ios && snapshot.config.platforms.ios
      ? await createIosAdapter(snapshot.platformPaths.ios, {
          sourceLocale: snapshot.config.source_locale,
          ...(snapshot.config.platforms.ios.key_transform
            ? { keyTransform: snapshot.config.platforms.ios.key_transform }
            : {}),
        })
          .inspect(snapshot.platformPaths.ios)
          .catch(() => null)
      : null;
  const androidPlatformReport =
    snapshot.platformPaths.android && snapshot.config.platforms.android
      ? await new AndroidStringsAdapter({
          sourceLocale: snapshot.config.source_locale,
          ...(snapshot.config.platforms.android.key_transform
            ? { keyTransform: snapshot.config.platforms.android.key_transform }
            : {}),
        })
          .inspect(snapshot.platformPaths.android)
          .catch(() => null)
      : null;

  return {
    cache_entries: snapshot.cache.value ? snapshot.cache.value.entries.length : 0,
    codex,
    diagnostics: snapshot.diagnostics,
    estimated_requests: {
      notes: estimatedRequests?.notes ?? null,
      requests: estimatedRequests?.requests ?? null,
    },
    history_entries: historyEntries.length,
    last_history_at: lastHistoryAt,
    locales,
    platforms: (['ios', 'android'] as const).map((platform) => ({
      configured: snapshot.platformPaths[platform] !== null,
      key_count:
        platform === 'ios'
          ? iosPlatformReport?.keyCount ?? null
          : androidPlatformReport?.keyCount ?? null,
      locales: platform === 'ios' ? iosPlatformReport?.locales ?? [] : androidPlatformReport?.locales ?? [],
      path: snapshot.platformPaths[platform],
      platform,
      version: platform === 'ios' ? iosPlatformReport?.version ?? null : null,
    })),
    source_keys: sourceKeys.length,
  };
}
