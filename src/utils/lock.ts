import { open, readFile, rm, stat } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { resolve } from 'node:path';
import process from 'node:process';

import { z } from 'zod';

import { L10nError } from '../errors/l10n-error.js';

const LOCK_STALE_AFTER_MS = 10 * 60 * 1000;

const SyncLockFileSchema = z.object({
  pid: z.number().int().positive(),
  started_at: z.string().datetime(),
  updated_at: z.string().datetime(),
  version: z.literal(1),
});

type SyncLockFile = z.infer<typeof SyncLockFileSchema>;

export interface SyncLockStatus {
  exists: boolean;
  path: string;
  pid: number | null;
  started_at: string | null;
  state: 'missing' | 'running' | 'stale';
  updated_at: string | null;
}

export interface SyncLockHandle {
  path: string;
  refresh(): Promise<void>;
  release(): Promise<void>;
}

function getSyncLockPath(l10nDir: string): string {
  return resolve(l10nDir, '.lock');
}

function isPidRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM';
  }
}

async function writeLockFile(path: string, value: SyncLockFile, flags: 'r+' | 'wx'): Promise<void> {
  const fileHandle = await open(path, flags);
  try {
    if (flags === 'r+') {
      await fileHandle.truncate(0);
    }
    await fileHandle.writeFile(`${JSON.stringify(value, null, 2)}\n`, 'utf8');
    await fileHandle.sync();
  } finally {
    await fileHandle.close();
  }
}

async function parseLockFile(path: string): Promise<SyncLockFile | null> {
  try {
    const raw = await readFile(path, 'utf8');
    const parsed = JSON.parse(raw);
    const result = SyncLockFileSchema.safeParse(parsed);
    return result.success ? result.data : null;
  } catch {
    return null;
  }
}

export async function inspectSyncLock(l10nDir: string): Promise<SyncLockStatus> {
  const path = getSyncLockPath(l10nDir);

  try {
    await open(path, fsConstants.O_RDONLY).then((handle) => handle.close());
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return {
        exists: false,
        path,
        pid: null,
        started_at: null,
        state: 'missing',
        updated_at: null,
      };
    }

    throw error;
  }

  const [metadata, stats] = await Promise.all([parseLockFile(path), stat(path)]);
  const ageMs = Date.now() - stats.mtimeMs;
  const pid = metadata?.pid ?? null;
  const running = pid !== null ? isPidRunning(pid) : false;
  const stale = !running && ageMs > LOCK_STALE_AFTER_MS;

  return {
    exists: true,
    path,
    pid,
    started_at: metadata?.started_at ?? null,
    state: stale ? 'stale' : 'running',
    updated_at: metadata?.updated_at ?? null,
  };
}

export async function acquireSyncLock(l10nDir: string): Promise<SyncLockHandle> {
  const path = getSyncLockPath(l10nDir);
  const now = new Date().toISOString();
  const lockFile: SyncLockFile = {
    pid: process.pid,
    started_at: now,
    updated_at: now,
    version: 1,
  };

  try {
    await writeLockFile(path, lockFile, 'wx');
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') {
      throw error;
    }

    const current = await inspectSyncLock(l10nDir);
    if (current.state !== 'stale') {
      throw new L10nError({
        code: 'L10N_E0079',
        details: {
          path: current.path,
          ...(current.pid ? { pid: current.pid } : {}),
          ...(current.started_at ? { started_at: current.started_at } : {}),
        },
        level: 'error',
        next: 'Wait for the current sync to finish, or remove a stale lock after confirming no sync is active.',
        summary: 'Another sync is already running',
      });
    }

    await rm(path, { force: true });
    await writeLockFile(path, lockFile, 'wx');
  }

  return {
    path,
    async refresh() {
      const updatedAt = new Date().toISOString();
      await writeLockFile(path, {
        ...lockFile,
        updated_at: updatedAt,
      }, 'r+');
    },
    async release() {
      await rm(path, { force: true });
    },
  };
}
