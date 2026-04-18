import process from 'node:process';

import { Chalk } from 'chalk';

import type { Diagnostic } from '../core/diagnostics.js';
import type { CheckReport } from '../core/check.js';
import type { DedupeReport } from '../core/dedupe.js';
import type { DoctorReport } from '../core/doctor.js';
import type { ImportReport } from '../core/import.js';
import type { InitReport } from '../core/init.js';
import type { RenameReport } from '../core/rename.js';
import type { RollbackReport } from '../core/rollback.js';
import type { SyncPlan, SyncReport } from '../core/sync.js';

export interface OutputOptions {
  color: boolean;
  json: boolean;
}

function createChalk(enabled: boolean) {
  return new Chalk({ level: enabled ? 1 : 0 });
}

export function printDiagnosticsReport(
  report: CheckReport | { diagnostics: Diagnostic[]; ok: boolean; summary: Record<string, unknown> },
  options: OutputOptions,
): void {
  if (options.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  const colors = createChalk(options.color);
  for (const diagnostic of report.diagnostics) {
    const level =
      diagnostic.level === 'error'
        ? colors.red(diagnostic.level)
        : diagnostic.level === 'warn'
          ? colors.yellow(diagnostic.level)
          : colors.blue(diagnostic.level);

    process.stdout.write(`${level}  ${diagnostic.code}  ${diagnostic.summary}\n`);
    for (const [key, value] of Object.entries(diagnostic.details ?? {})) {
      process.stdout.write(`       ${key}: ${String(value)}\n`);
    }
    if (diagnostic.next) {
      process.stdout.write(`       next: ${diagnostic.next}\n`);
    }
  }

  const statusText = report.ok ? colors.green('ok') : colors.red('failed');
  process.stdout.write(`\n${statusText}  ${JSON.stringify(report.summary)}\n`);
}

export function printDoctorReport(report: DoctorReport, options: OutputOptions): void {
  if (options.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  const colors = createChalk(options.color);
  process.stdout.write(`Source keys: ${report.source_keys}\n`);
  process.stdout.write(
    `Codex: ${report.codex.loginStatus}, version ${report.codex.detectedVersion ?? 'unavailable'}, minimum ${report.codex.minimumVersion}\n`,
  );
  process.stdout.write(
    `Cache entries: ${report.cache_entries}, history entries: ${report.history_entries}, last history: ${report.last_history_at ?? 'none'}\n`,
  );
  process.stdout.write(
    `Next sync estimate: ${report.estimated_requests.requests ?? 'unavailable'}${
      report.estimated_requests.notes ? ` (${report.estimated_requests.notes})` : ''
    }\n`,
  );
  process.stdout.write('\nLocales:\n');
  for (const locale of report.locales) {
    const missingText = locale.missing > 0 ? colors.red(String(locale.missing)) : colors.green('0');
    const staleText = locale.stale > 0 ? colors.yellow(String(locale.stale)) : colors.green('0');
    process.stdout.write(
      `  ${locale.locale}: total=${locale.total_entries} missing=${missingText} stale=${staleText} reviewed=${locale.reviewed} machine=${locale.machine_translated} orphaned=${locale.orphaned}\n`,
    );
  }

  process.stdout.write('\nPlatforms:\n');
  for (const platform of report.platforms) {
    process.stdout.write(
      `  ${platform.platform}: ${
        platform.configured ? platform.path : 'disabled'
      }${platform.key_count !== null ? ` keys=${platform.key_count}` : ''}${
        platform.locales.length > 0 ? ` locales=${platform.locales.join(',')}` : ''
      }${platform.version ? ` version=${platform.version}` : ''}\n`,
    );
  }
}

export function printSyncPlan(plan: SyncPlan, report: SyncReport, options: OutputOptions): void {
  if (options.json) {
    process.stdout.write(`${JSON.stringify({ plan, report }, null, 2)}\n`);
    return;
  }

  process.stdout.write('Plan for sync:\n');
  for (const locale of plan.locales) {
    process.stdout.write(
      `  ${locale.locale}: missing=${locale.missing} stale=${locale.stale_retranslations} reviewed_stale=${locale.reviewed_stale} removed=${locale.removed} cache_hits=${locale.cache_hits}\n`,
    );
  }
  process.stdout.write(
    `Estimated provider requests: ${report.summary.provider_requests}, platform writes ios=${plan.platform_writes.ios} android=${plan.platform_writes.android}\n`,
  );
  if (report.resumed_from) {
    process.stdout.write(
      `Resuming partial sync from ${report.resumed_from.started_at} - ${report.resumed_from.remaining_translations} translations remaining\n`,
    );
  }
  for (const diagnostic of report.diagnostics) {
    process.stdout.write(`${diagnostic.level}  ${diagnostic.code}  ${diagnostic.summary}\n`);
  }
}

export function printSyncReport(report: SyncReport, options: OutputOptions): void {
  if (options.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  const colors = createChalk(options.color);
  if (report.resumed_from) {
    process.stdout.write(
      `Resuming partial sync from ${report.resumed_from.started_at} - ${report.resumed_from.remaining_translations} translations remaining\n`,
    );
  }

  for (const diagnostic of report.diagnostics) {
    const level =
      diagnostic.level === 'error'
        ? colors.red(diagnostic.level)
        : diagnostic.level === 'warn'
          ? colors.yellow(diagnostic.level)
          : colors.blue(diagnostic.level);
    process.stdout.write(`${level}  ${diagnostic.code}  ${diagnostic.summary}\n`);
    for (const [key, value] of Object.entries(diagnostic.details ?? {})) {
      process.stdout.write(`       ${key}: ${String(value)}\n`);
    }
    if (diagnostic.next) {
      process.stdout.write(`       next: ${diagnostic.next}\n`);
    }
  }

  const statusText = report.ok ? colors.green('ok') : colors.red('failed');
  process.stdout.write(`\n${statusText}  ${JSON.stringify(report.summary)}\n`);
}

export function printDedupeReport(report: DedupeReport, options: OutputOptions): void {
  if (options.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  const colors = createChalk(options.color);
  for (const group of report.exact_duplicates) {
    process.stdout.write(
      `${colors.yellow('warn')}  L10N_E0070  exact duplicate: ${group.keys.join(', ')}\n`,
    );
    process.stdout.write(`       text: ${group.text}\n`);
  }

  for (const group of report.semantic_duplicates) {
    process.stdout.write(
      `${colors.yellow('warn')}  L10N_E0071  semantic duplicate: ${group.canonical_key} <- ${group.duplicate_keys.join(', ')}\n`,
    );
    process.stdout.write(`       confidence: ${group.confidence.toFixed(2)}\n`);
    process.stdout.write(`       model: ${group.model_version}\n`);
    process.stdout.write(`       rationale: ${group.rationale}\n`);
  }

  process.stdout.write(
    `\nok  ${JSON.stringify(report.summary)}\n`,
  );
}

export function printRenameReport(report: RenameReport, options: OutputOptions): void {
  printDiagnosticsReport(report, options);
}

export function printImportReport(report: ImportReport, options: OutputOptions): void {
  if (options.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  process.stdout.write(`Imported from ${report.summary.from}\n`);
  process.stdout.write(`Source keys: ${report.summary.source_keys}\n`);
  for (const locale of report.summary.locales) {
    process.stdout.write(`  ${locale.locale}: imported=${locale.imported} missing=${locale.missing}\n`);
  }
}

export function printRollbackReport(report: RollbackReport, options: OutputOptions): void {
  if (options.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  process.stdout.write(`Rolled back repo state to before history entry ${report.summary.restored_to}\n`);
}

export function printInitReport(report: InitReport, options: OutputOptions): void {
  if (options.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return;
  }

  process.stdout.write(`Created ${report.summary.config_path}\n`);
  process.stdout.write(
    `Locales: ${report.summary.source_locale} -> ${report.summary.target_locales.join(', ')}\n`,
  );
  process.stdout.write(
    `Codex preflight: ${report.preflight.loginStatus}, version ${report.preflight.detectedVersion ?? 'unavailable'}\n`,
  );
  if (report.imported_from) {
    process.stdout.write(`Imported existing strings from ${report.imported_from}\n`);
  }
}
