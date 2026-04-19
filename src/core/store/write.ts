import { rm } from 'node:fs/promises';

import { appendTextFile, writeJsonFileAtomic } from '../../utils/fs.js';
import type {
  CacheEntry,
  CacheFile,
  HistoryEntry,
  SyncStateFile,
  TranslationEntry,
  TranslationFile,
} from './schemas.js';

export function createTranslationFile(
  locale: string,
  entries: Record<string, TranslationEntry> = {},
): TranslationFile {
  return {
    entries,
    locale,
    version: 1,
  };
}

export async function writeTranslationFile(
  path: string,
  locale: string,
  entries: Record<string, TranslationEntry>,
): Promise<void> {
  await writeJsonFileAtomic(path, createTranslationFile(locale, entries));
}

export async function writeCacheFile(
  path: string,
  entries: CacheFile['entries'],
): Promise<void> {
  const sortedEntries = [...entries].sort(
    (left, right) =>
      left.source_hash.localeCompare(right.source_hash) ||
      left.locale.localeCompare(right.locale) ||
      left.config_hash.localeCompare(right.config_hash) ||
      left.model_version.localeCompare(right.model_version) ||
      left.cached_at.localeCompare(right.cached_at),
  );
  await writeJsonFileAtomic(path, {
    entries: sortedEntries,
    version: 3,
  } satisfies CacheFile);
}

export async function writeSyncState(path: string, state: SyncStateFile): Promise<void> {
  await writeJsonFileAtomic(path, state);
}

export async function removeFileIfExists(path: string): Promise<void> {
  try {
    await rm(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      throw error;
    }
  }
}

export async function appendHistoryEntries(
  path: string,
  newEntries: HistoryEntry[],
): Promise<void> {
  if (newEntries.length === 0) {
    return;
  }

  const lines = newEntries.map((entry) => JSON.stringify(entry));
  await appendTextFile(path, `${lines.join('\n')}\n`);
}

export function garbageCollectCache(
  entries: CacheEntry[],
  activeSourceHashes: Set<string>,
): CacheEntry[] {
  const live = entries.filter((entry) => activeSourceHashes.has(entry.source_hash));

  const groupMap = new Map<string, CacheEntry[]>();
  for (const entry of live) {
    const groupKey = `${entry.source_hash}|${entry.locale}|${entry.config_hash}`;
    const group = groupMap.get(groupKey) ?? [];
    group.push(entry);
    groupMap.set(groupKey, group);
  }

  return [...groupMap.values()].flatMap((group) =>
    group.sort((left, right) => right.cached_at.localeCompare(left.cached_at)).slice(0, 2),
  );
}

export function upsertCacheEntry(entries: CacheEntry[], entry: CacheEntry): CacheEntry[] {
  return [
    ...entries.filter(
      (current) =>
        !(
          current.source_hash === entry.source_hash &&
          current.locale === entry.locale &&
          current.config_hash === entry.config_hash &&
          current.model_version === entry.model_version
        ),
    ),
    entry,
  ];
}
