import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

import { stableStringify } from './json.js';

export async function readTextFile(path: string): Promise<string> {
  return readFile(path, 'utf8');
}

export async function readJsonFile(path: string): Promise<unknown> {
  return JSON.parse(await readTextFile(path));
}

export async function writeTextFileAtomic(path: string, value: string): Promise<void> {
  const parentDir = dirname(path);
  const temporaryPath = `${path}.tmp`;

  await mkdir(parentDir, { recursive: true });
  await writeFile(temporaryPath, value, 'utf8');
  await rename(temporaryPath, path);
}

export async function writeJsonFileAtomic(path: string, value: unknown): Promise<void> {
  await writeTextFileAtomic(path, stableStringify(value));
}
