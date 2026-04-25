import { mkdir, open, readFile, rename, rm } from 'node:fs/promises';
import { dirname } from 'node:path';
import process from 'node:process';

import { stableStringify } from './json.js';

export async function readTextFile(path: string): Promise<string> {
  return readFile(path, 'utf8');
}

export async function readJsonFile(path: string): Promise<unknown> {
  return JSON.parse(await readTextFile(path));
}

async function fsyncDirectory(path: string): Promise<void> {
  try {
    const directoryHandle = await open(path, 'r');
    try {
      await directoryHandle.sync();
    } finally {
      await directoryHandle.close();
    }
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (!['EINVAL', 'ENOTSUP', 'EISDIR', 'EPERM'].includes(code ?? '')) {
      throw error;
    }
  }
}

export async function writeTextFileAtomic(path: string, value: string): Promise<void> {
  const parentDir = dirname(path);
  const temporaryPath = `${path}.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}.tmp`;

  await mkdir(parentDir, { recursive: true });
  const fileHandle = await open(temporaryPath, 'w');

  try {
    await fileHandle.writeFile(value, 'utf8');
    await fileHandle.sync();
  } catch (error) {
    await fileHandle.close().catch(() => undefined);
    await rm(temporaryPath, { force: true }).catch(() => undefined);
    throw error;
  }

  await fileHandle.close();
  await rename(temporaryPath, path);
  await fsyncDirectory(parentDir);
}

export async function appendTextFile(path: string, value: string): Promise<void> {
  const parentDir = dirname(path);
  await mkdir(parentDir, { recursive: true });

  const fileHandle = await open(path, 'a');
  try {
    await fileHandle.writeFile(value, 'utf8');
    await fileHandle.sync();
  } finally {
    await fileHandle.close();
  }
  await fsyncDirectory(parentDir);
}

export async function writeJsonFileAtomic(path: string, value: unknown): Promise<void> {
  await writeTextFileAtomic(path, stableStringify(value));
}
