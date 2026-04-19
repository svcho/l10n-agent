import { dirname, resolve } from 'node:path';

import { loadConfig } from '../config/load.js';
import { readTextFile, writeJsonFileAtomic } from '../utils/fs.js';
import { acquireSyncLock } from '../utils/lock.js';
import { sortValueDeep } from '../utils/json.js';
import type { Diagnostic } from './diagnostics.js';
import { hasErrorDiagnostics } from './diagnostics.js';
import { buildHistoryId, createRepairHistoryEntry } from './history.js';
import { snapshotManagedFiles } from './project-files.js';
import type { HistoryEntry } from './store/schemas.js';
import { appendHistoryEntries } from './store/write.js';

interface ConflictVariants {
  left: string;
  right: string;
}

interface RepairContext {
  historyPath: string;
  l10nDir: string;
  rootDir: string;
  sourceLocale: string;
  targetLocales: string[];
}

export interface RepairReport {
  diagnostics: Diagnostic[];
  ok: boolean;
  summary: {
    auto_merged: number;
    files_scanned: number;
    reformatted: number;
  };
}

function hasConflictMarkers(text: string): boolean {
  return text.includes('<<<<<<< ') && text.includes('=======') && text.includes('>>>>>>> ');
}

function extractConflictVariants(text: string): ConflictVariants | null {
  const lines = text.split('\n');
  const left: string[] = [];
  const right: string[] = [];
  let index = 0;
  let sawConflict = false;

  while (index < lines.length) {
    const line = lines[index] ?? '';
    if (!line.startsWith('<<<<<<< ')) {
      left.push(line);
      right.push(line);
      index += 1;
      continue;
    }

    sawConflict = true;
    index += 1;
    const leftChunk: string[] = [];
    const rightChunk: string[] = [];

    while (index < lines.length && lines[index] !== '=======') {
      leftChunk.push(lines[index] ?? '');
      index += 1;
    }

    if (index >= lines.length) {
      return null;
    }

    index += 1;
    while (index < lines.length && !lines[index]!.startsWith('>>>>>>> ')) {
      rightChunk.push(lines[index] ?? '');
      index += 1;
    }

    if (index >= lines.length) {
      return null;
    }

    index += 1;
    left.push(...leftChunk);
    right.push(...rightChunk);
  }

  return sawConflict
    ? {
        left: left.join('\n'),
        right: right.join('\n'),
      }
    : null;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function mergeJsonValues(
  left: unknown,
  right: unknown,
  path: string[] = [],
): { conflictPath: string | null; value: unknown } {
  if (isPlainObject(left) && isPlainObject(right)) {
    const merged: Record<string, unknown> = {};
    const keys = new Set([...Object.keys(left), ...Object.keys(right)]);

    for (const key of [...keys].sort()) {
      if (!(key in left)) {
        merged[key] = right[key];
        continue;
      }

      if (!(key in right)) {
        merged[key] = left[key];
        continue;
      }

      const result = mergeJsonValues(left[key], right[key], [...path, key]);
      if (result.conflictPath) {
        return result;
      }
      merged[key] = result.value;
    }

    return { conflictPath: null, value: merged };
  }

  if (JSON.stringify(left) === JSON.stringify(right)) {
    return { conflictPath: null, value: left };
  }

  return {
    conflictPath: path.join('.'),
    value: null,
  };
}

function getRepairCandidatePaths(context: RepairContext): string[] {
  return [
    resolve(context.l10nDir, '.cache.json'),
    resolve(context.l10nDir, '.state.json'),
    resolve(context.l10nDir, `source.${context.sourceLocale}.json`),
    ...context.targetLocales.map((locale) => resolve(context.l10nDir, `translations.${locale}.json`)),
  ].sort();
}

async function loadRepairContext(
  rootDir: string,
  explicitConfigPath?: string,
): Promise<RepairContext> {
  const { config, path: configPath } = await loadConfig(rootDir, explicitConfigPath);
  const l10nDir = dirname(configPath);
  return {
    historyPath: resolve(l10nDir, '.history.jsonl'),
    l10nDir,
    rootDir,
    sourceLocale: config.source_locale,
    targetLocales: config.target_locales,
  };
}

async function loadExistingHistoryEntries(path: string): Promise<HistoryEntry[] | null> {
  try {
    const rawText = await readTextFile(path);
    if (rawText.trim().length === 0) {
      return [];
    }

    try {
      return rawText
        .trim()
        .split('\n')
        .map((line) => JSON.parse(line) as HistoryEntry);
    } catch {
      return null;
    }
  } catch {
    return [];
  }
}

export async function runRepair(
  rootDir: string,
  explicitConfigPath?: string,
  options: {
    dryRun?: boolean;
  } = {},
): Promise<RepairReport> {
  const context = await loadRepairContext(rootDir, explicitConfigPath);
  const diagnostics: Diagnostic[] = [];
  const files = getRepairCandidatePaths(context);
  const rewritten = new Map<string, unknown>();
  let reformatted = 0;
  let autoMerged = 0;

  for (const path of files) {
    let rawText: string;
    try {
      rawText = await readTextFile(path);
    } catch {
      continue;
    }

    let parsed: unknown;
    if (hasConflictMarkers(rawText)) {
      const variants = extractConflictVariants(rawText);
      if (!variants) {
        diagnostics.push({
          code: 'L10N_E0088',
          details: { path },
          level: 'error',
          next: 'Resolve the malformed git conflict markers manually, then rerun repair.',
          summary: 'Repair could not parse conflict markers in a managed JSON file',
        });
        continue;
      }

      let leftParsed: unknown;
      let rightParsed: unknown;
      try {
        leftParsed = JSON.parse(variants.left);
        rightParsed = JSON.parse(variants.right);
      } catch {
        diagnostics.push({
          code: 'L10N_E0088',
          details: { path },
          level: 'error',
          next: 'Resolve the conflict manually; repair only auto-merges valid JSON on both sides.',
          summary: 'Repair could not parse both conflict sides as JSON',
        });
        continue;
      }

      const merged = mergeJsonValues(leftParsed, rightParsed);
      if (merged.conflictPath) {
        diagnostics.push({
          code: 'L10N_E0088',
          details: {
            conflict_path: merged.conflictPath,
            path,
          },
          level: 'error',
          next: 'Resolve the overlapping JSON edit manually, then rerun repair for canonical ordering.',
          summary: 'Repair found overlapping JSON edits that it cannot merge safely',
        });
        continue;
      }

      parsed = merged.value;
      autoMerged += 1;
    } else {
      try {
        parsed = JSON.parse(rawText);
      } catch {
        diagnostics.push({
          code: 'L10N_E0088',
          details: { path },
          level: 'error',
          next: 'Fix the JSON syntax manually, then rerun repair.',
          summary: 'Repair could not parse a managed JSON file',
        });
        continue;
      }
    }

    const sorted = sortValueDeep(parsed);
    const normalized = `${JSON.stringify(sorted, null, 2)}\n`;
    if (normalized !== rawText) {
      reformatted += 1;
      rewritten.set(path, sorted);
    }
  }

  const report: RepairReport = {
    diagnostics,
    ok: !hasErrorDiagnostics(diagnostics),
    summary: {
      auto_merged: autoMerged,
      files_scanned: files.length,
      reformatted,
    },
  };

  if (options.dryRun || rewritten.size === 0) {
    return report;
  }

  const lock = await acquireSyncLock(context.l10nDir);
  try {
    const timestamp = new Date().toISOString();
    const historyId = buildHistoryId(timestamp, 'repair');
    await snapshotManagedFiles(context.rootDir, context.l10nDir, historyId, files);

    for (const [path, value] of [...rewritten.entries()].sort(([left], [right]) => left.localeCompare(right))) {
      await writeJsonFileAtomic(path, value);
    }

    const existingHistory = await loadExistingHistoryEntries(context.historyPath);
    if (existingHistory !== null) {
      await appendHistoryEntries(context.historyPath, [
        createRepairHistoryEntry(historyId, timestamp, `Repair rewrote ${rewritten.size} managed JSON files`),
      ]);
    }
  } finally {
    await lock.release().catch(() => undefined);
  }

  return report;
}
