import { IosXcstringsAdapter } from '../adapters/ios/xcstrings.js';
import type { ProjectSnapshot } from './store/load.js';
import type { CodexPreflightResult } from '../providers/codex-local.js';

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
): Promise<DoctorReport> {
  const sourceKeys = Object.keys(snapshot.source.value.keys);
  const sourceKeySet = new Set(sourceKeys);

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
      ? await new IosXcstringsAdapter({
          sourceLocale: snapshot.config.source_locale,
          ...(snapshot.config.platforms.ios.key_transform
            ? { keyTransform: snapshot.config.platforms.ios.key_transform }
            : {}),
        })
          .inspect(snapshot.platformPaths.ios)
          .catch(() => null)
      : null;

  return {
    cache_entries: snapshot.cache.value ? Object.keys(snapshot.cache.value.entries).length : 0,
    codex: await preflight(),
    history_entries: historyEntries.length,
    last_history_at: lastHistoryAt,
    locales,
    platforms: (['ios', 'android'] as const).map((platform) => ({
      configured: snapshot.platformPaths[platform] !== null,
      key_count: platform === 'ios' ? iosPlatformReport?.keyCount ?? null : null,
      locales: platform === 'ios' ? iosPlatformReport?.locales ?? [] : [],
      path: snapshot.platformPaths[platform],
      platform,
      version: platform === 'ios' ? iosPlatformReport?.version ?? null : null,
    })),
    source_keys: sourceKeys.length,
  };
}
