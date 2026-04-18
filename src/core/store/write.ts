import { rm } from 'node:fs/promises';

import { writeJsonFileAtomic, writeTextFileAtomic } from '../../utils/fs.js';
import type {
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
  await writeJsonFileAtomic(path, {
    entries,
    version: 1,
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
  existingEntries: HistoryEntry[] | null,
  newEntries: HistoryEntry[],
): Promise<void> {
  if (newEntries.length === 0) {
    return;
  }

  const lines = [...(existingEntries ?? []), ...newEntries].map((entry) => JSON.stringify(entry));
  await writeTextFileAtomic(path, `${lines.join('\n')}\n`);
}
