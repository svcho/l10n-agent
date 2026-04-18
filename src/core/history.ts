import { userInfo } from 'node:os';

import type { HistoryEntry } from './store/schemas.js';

export function getActor(): string {
  try {
    return userInfo().username;
  } catch {
    return process.env.USER ?? 'unknown';
  }
}

export function buildHistoryId(timestamp: string, suffix: string): string {
  return `${timestamp.replaceAll(/[-:.TZ]/g, '').slice(0, 14)}-${suffix}`;
}

export function createInitHistoryEntry(id: string, timestamp: string, summary: string): HistoryEntry {
  return {
    actor: getActor(),
    id,
    op: 'init',
    summary,
    ts: timestamp,
  };
}

export function createSyncHistoryEntry(id: string, timestamp: string, summary: string): HistoryEntry {
  return {
    actor: getActor(),
    id,
    op: 'sync',
    summary,
    ts: timestamp,
  };
}

export function createImportHistoryEntry(
  id: string,
  timestamp: string,
  from: string,
  summary: string,
): HistoryEntry {
  return {
    actor: getActor(),
    from,
    id,
    op: 'import',
    summary,
    ts: timestamp,
  };
}

export function createRenameHistoryEntry(
  id: string,
  timestamp: string,
  before: string,
  after: string,
): HistoryEntry {
  return {
    actor: getActor(),
    after,
    before,
    id,
    op: 'rename',
    ts: timestamp,
  };
}

export function createLintFixHistoryEntry(
  id: string,
  timestamp: string,
  renames: Array<{ after: string; before: string }>,
  filesUpdated: number,
): HistoryEntry {
  return {
    actor: getActor(),
    files_updated: filesUpdated,
    id,
    op: 'lint_fix',
    renames,
    ts: timestamp,
  };
}

export function createRollbackHistoryEntry(id: string, timestamp: string, to: string): HistoryEntry {
  return {
    actor: getActor(),
    id,
    op: 'rollback',
    to,
    ts: timestamp,
  };
}

export function createAddLocaleHistoryEntry(id: string, timestamp: string, locale: string): HistoryEntry {
  return {
    actor: getActor(),
    id,
    locale,
    op: 'add_locale',
    ts: timestamp,
  };
}

export function createRemoveLocaleHistoryEntry(id: string, timestamp: string, locale: string): HistoryEntry {
  return {
    actor: getActor(),
    id,
    locale,
    op: 'remove_locale',
    ts: timestamp,
  };
}

export function createRepairHistoryEntry(id: string, timestamp: string, summary: string): HistoryEntry {
  return {
    actor: getActor(),
    id,
    op: 'repair',
    summary,
    ts: timestamp,
  };
}
