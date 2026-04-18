import { readFile } from 'node:fs/promises';
import { relative, resolve, sep } from 'node:path';

import {
  buildCanonicalKeySetFromSource,
  buildCanonicalKeySetFromTranslation,
} from '../adapters/canonical.js';
import { AndroidStringsAdapter } from '../adapters/android/strings.js';
import { createIosAdapter } from '../adapters/ios/index.js';
import { isIosStringsPath, resolveIosStringsLocalePath } from '../adapters/ios/strings.js';
import { L10nError } from '../errors/l10n-error.js';
import { readJsonFile, writeJsonFileAtomic, writeTextFileAtomic } from '../utils/fs.js';
import type { ProjectSnapshot } from './store/load.js';
import type { CacheFile, SourceFile, TranslationEntry } from './store/schemas.js';
import {
  removeFileIfExists,
  writeCacheFile,
  writeTranslationFile,
} from './store/write.js';

interface ManagedFileSnapshot {
  files: Record<string, string | null>;
  version: 1;
}

export interface TranslationLocaleState {
  entries: Record<string, TranslationEntry>;
  locale: string;
  path: string;
}

export function resolveManagedSnapshotPath(l10nDir: string, historyId: string): string {
  return resolve(l10nDir, '.snapshots', `${historyId}.json`);
}

export async function loadManagedSnapshot(l10nDir: string, historyId: string): Promise<ManagedFileSnapshot> {
  const snapshotPath = resolveManagedSnapshotPath(l10nDir, historyId);
  let snapshot: unknown;

  try {
    snapshot = await readJsonFile(snapshotPath);
  } catch {
    throw new L10nError({
      code: 'L10N_E0062',
      details: { history_id: historyId, path: snapshotPath },
      level: 'error',
      next: 'Choose a history entry created by this version of l10n-agent, or restore files from git.',
      summary: 'Rollback snapshot could not be loaded',
    });
  }

  if (
    !snapshot ||
    typeof snapshot !== 'object' ||
    Array.isArray(snapshot) ||
    !('version' in snapshot) ||
    snapshot.version !== 1 ||
    !('files' in snapshot) ||
    !snapshot.files ||
    typeof snapshot.files !== 'object' ||
    Array.isArray(snapshot.files)
  ) {
    throw new L10nError({
      code: 'L10N_E0062',
      details: { history_id: historyId, path: snapshotPath },
      level: 'error',
      next: 'Delete the malformed snapshot and restore the repo from git if needed.',
      summary: 'Rollback snapshot has an invalid shape',
    });
  }

  return snapshot as ManagedFileSnapshot;
}

/**
 * Validates that a managed snapshot exists, is structurally sound, and that
 * every file path it contains resolves safely within rootDir (no path traversal).
 * Throws L10N_E0062 on any violation so callers can fail-fast before side effects.
 */
export async function validateManagedSnapshot(
  rootDir: string,
  l10nDir: string,
  historyId: string,
): Promise<void> {
  const snapshot = await loadManagedSnapshot(l10nDir, historyId);

  for (const relativePath of Object.keys(snapshot.files)) {
    const absolute = resolve(rootDir, relativePath);
    if (absolute !== rootDir && !absolute.startsWith(rootDir + sep)) {
      throw new L10nError({
        code: 'L10N_E0062',
        details: { file: relativePath, history_id: historyId },
        level: 'error',
        next: 'Do not use manually edited snapshot files. Restore files from git if needed.',
        summary: 'Rollback snapshot contains a path that escapes the project root',
      });
    }
  }
}

export function getManagedFilePaths(snapshot: ProjectSnapshot): string[] {
  const filePaths = new Set<string>([
    snapshot.source.path,
    snapshot.cache.path,
    snapshot.state.path,
    ...snapshot.translations.map((translation) => translation.path),
  ]);

  for (const platformPath of Object.values(snapshot.platformPaths)) {
    if (platformPath) {
      filePaths.add(platformPath);
    }
  }

  if (snapshot.platformPaths.ios && isIosStringsPath(snapshot.platformPaths.ios)) {
    filePaths.add(
      resolveIosStringsLocalePath(
        snapshot.platformPaths.ios,
        snapshot.config.source_locale,
        snapshot.config.source_locale,
      ),
    );
    for (const translation of snapshot.translations) {
      filePaths.add(
        resolveIosStringsLocalePath(
          snapshot.platformPaths.ios,
          snapshot.config.source_locale,
          translation.locale,
        ),
      );
    }
  }

  return [...filePaths].sort();
}

export function getManagedFilePathsWithExtras(snapshot: ProjectSnapshot, extraPaths: string[] = []): string[] {
  return [...new Set([...getManagedFilePaths(snapshot), ...extraPaths])].sort();
}

export async function snapshotManagedFiles(
  rootDir: string,
  l10nDir: string,
  historyId: string,
  filePaths: string[],
): Promise<void> {
  const files: Record<string, string | null> = {};

  for (const filePath of [...new Set(filePaths)].sort()) {
    const relativePath = relative(rootDir, filePath);
    try {
      files[relativePath] = await readFile(filePath, 'utf8');
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        files[relativePath] = null;
        continue;
      }

      throw error;
    }
  }

  await writeJsonFileAtomic(resolveManagedSnapshotPath(l10nDir, historyId), {
    files,
    version: 1,
  } satisfies ManagedFileSnapshot);
}

export async function restoreManagedFiles(
  rootDir: string,
  l10nDir: string,
  historyId: string,
): Promise<void> {
  const snapshotPath = resolveManagedSnapshotPath(l10nDir, historyId);
  const snapshot = await loadManagedSnapshot(l10nDir, historyId);

  for (const [relativePath, content] of Object.entries(snapshot.files as Record<string, unknown>).sort(([left], [right]) =>
    left.localeCompare(right),
  )) {
    const absolutePath = resolve(rootDir, relativePath);
    if (content === null) {
      await removeFileIfExists(absolutePath);
      continue;
    }

    if (typeof content !== 'string') {
      throw new L10nError({
        code: 'L10N_E0062',
        details: { history_id: historyId, path: snapshotPath, file: relativePath },
        level: 'error',
        next: 'Delete the malformed snapshot and restore the repo from git if needed.',
        summary: 'Rollback snapshot contains a non-text file entry',
      });
    }

    await writeTextFileAtomic(absolutePath, content);
  }
}

export async function getSnapshotTrackedFilePaths(
  rootDir: string,
  l10nDir: string,
  historyId: string,
): Promise<string[]> {
  const snapshot = await loadManagedSnapshot(l10nDir, historyId);

  return Object.keys(snapshot.files)
    .map((relativePath) => resolve(rootDir, relativePath))
    .sort();
}

export async function writeSourceFile(path: string, source: SourceFile): Promise<void> {
  await writeJsonFileAtomic(path, source);
}

export async function writeProjectFiles(
  snapshot: ProjectSnapshot,
  source: SourceFile,
  translations: TranslationLocaleState[],
  options: {
    cacheEntries?: CacheFile['entries'];
    removeState?: boolean;
    removedLocales?: string[];
  } = {},
): Promise<void> {
  await writeSourceFile(snapshot.source.path, source);

  for (const translation of [...translations].sort((left, right) => left.locale.localeCompare(right.locale))) {
    await writeTranslationFile(translation.path, translation.locale, translation.entries);
  }

  if (options.cacheEntries !== undefined) {
    await writeCacheFile(snapshot.cache.path, options.cacheEntries);
  }

  if (snapshot.platformPaths.ios && snapshot.config.platforms.ios) {
    const adapter = createIosAdapter(snapshot.platformPaths.ios, {
      keyTransform: snapshot.config.platforms.ios.key_transform,
      sourceLocale: snapshot.config.source_locale,
    });

    await adapter.write(
      snapshot.platformPaths.ios,
      buildCanonicalKeySetFromSource(source),
      snapshot.config.source_locale,
    );

    for (const translation of translations) {
      await adapter.write(
        snapshot.platformPaths.ios,
        buildCanonicalKeySetFromTranslation(
          {
            entries: translation.entries,
            locale: translation.locale,
            version: 1,
          },
          source,
        ),
        translation.locale,
      );
    }

    for (const locale of [...new Set(options.removedLocales ?? [])].sort()) {
      await adapter.write(snapshot.platformPaths.ios, { keys: new Map() }, locale);
    }
  }

  if (snapshot.platformPaths.android && snapshot.config.platforms.android) {
    const adapter = new AndroidStringsAdapter({
      keyTransform: snapshot.config.platforms.android.key_transform,
      sourceLocale: snapshot.config.source_locale,
    });

    await adapter.write(
      snapshot.platformPaths.android,
      buildCanonicalKeySetFromSource(source),
      snapshot.config.source_locale,
    );

    for (const translation of translations) {
      await adapter.write(
        snapshot.platformPaths.android,
        buildCanonicalKeySetFromTranslation(
          {
            entries: translation.entries,
            locale: translation.locale,
            version: 1,
          },
          source,
        ),
        translation.locale,
      );
    }

    for (const locale of [...new Set(options.removedLocales ?? [])].sort()) {
      await adapter.write(snapshot.platformPaths.android, { keys: new Map() }, locale);
    }
  }

  if (options.removeState) {
    await removeFileIfExists(snapshot.state.path);
  }
}
