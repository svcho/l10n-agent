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
      left.model_version.localeCompare(right.model_version) ||
      left.cached_at.localeCompare(right.cached_at),
  );
  await writeJsonFileAtomic(path, {
    entries: sortedEntries,
    version: 2,
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
  _existingEntries: HistoryEntry[] | null,
  newEntries: HistoryEntry[],
): Promise<void> {
  if (newEntries.length === 0) {
    return;
  }

  const lines = newEntries.map((entry) => JSON.stringify(entry));
  await appendTextFile(path, `${lines.join('\n')}\n`);
}

export function upsertCacheEntry(entries: CacheEntry[], entry: CacheEntry): CacheEntry[] {
  return [
    ...entries.filter(
      (current) =>
        !(
          current.source_hash === entry.source_hash &&
          current.locale === entry.locale &&
          current.model_version === entry.model_version
        ),
    ),
    entry,
  ];
}
