import process from 'node:process';

import { lintSourceKeys } from './linter/lint-keys.js';
import { buildSyncPlan } from './sync.js';
import type { ProjectSnapshot } from './store/load.js';

export interface StatusReport {
  active_sync: ActiveSyncStatus | null;
  diagnostics: ReturnType<typeof lintSourceKeys>;
  locales: Array<{
    cache_hits: number;
    locale: string;
    missing: number;
    pending: number;
    reviewed_stale: number;
    stale_retranslations: number;
  }>;
  ok: boolean;
  summary: {
    cache_hits: number;
    pending_tasks: number;
    provider_requests: number;
    removed: number;
    reviewed_skipped: number;
    source_keys: number;
    sync_state: 'idle' | 'interrupted' | 'running';
  };
}

interface ActiveSyncStatus {
  completed_translations: number;
  current_key: string | null;
  current_locale: string | null;
  last_processed_key: string | null;
  last_processed_locale: string | null;
  percent_complete: number;
  pid: number | null;
  remaining_translations: number;
  started_at: string;
  state: 'interrupted' | 'running';
  total_translations: number;
  updated_at: string;
}

function isProcessRunning(pid?: number): boolean {
  if (!pid) {
    return false;
  }

  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM';
  }
}

export function buildStatusReport(
  snapshot: ProjectSnapshot,
  options: {
    locales?: string[];
  } = {},
): StatusReport {
  const diagnostics = lintSourceKeys(snapshot.config, snapshot.source.value);
  const plan = buildSyncPlan(snapshot, options.locales ? { locales: options.locales } : {});
  const state = snapshot.state.value;
  const syncState: ActiveSyncStatus | null =
    state === null
      ? null
      : {
          completed_translations: state.completed_translations,
          current_key: state.current_key ?? null,
          current_locale: state.current_locale ?? null,
          last_processed_key: state.last_processed_key ?? null,
          last_processed_locale: state.last_processed_locale ?? null,
          percent_complete:
            state.total_translations === 0
              ? 100
              : Math.min(100, Number(((state.completed_translations / state.total_translations) * 100).toFixed(1))),
          pid: state.pid ?? null,
          remaining_translations: Math.max(0, state.total_translations - state.completed_translations),
          started_at: state.started_at,
          state: isProcessRunning(state.pid) ? 'running' : 'interrupted',
          total_translations: state.total_translations,
          updated_at: state.updated_at,
        };

  return {
    active_sync: syncState,
    diagnostics,
    locales: plan.locales.map((locale) => ({
      cache_hits: locale.cache_hits,
      locale: locale.locale,
      missing: locale.missing,
      pending: locale.pending_tasks.length,
      reviewed_stale: locale.reviewed_stale,
      stale_retranslations: locale.stale_retranslations,
    })),
    ok: diagnostics.every((diagnostic) => diagnostic.level !== 'error'),
    summary: {
      cache_hits: plan.total_cache_hits,
      pending_tasks: plan.total_pending_tasks,
      provider_requests: plan.total_pending_tasks - plan.total_cache_hits,
      removed: plan.total_removed,
      reviewed_skipped: plan.review_skips,
      source_keys: plan.source_keys,
      sync_state: syncState?.state ?? 'idle',
    },
  };
}
