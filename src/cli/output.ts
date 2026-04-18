import process from 'node:process';

import { Chalk } from 'chalk';

import type { Diagnostic } from '../core/diagnostics.js';
import type { CheckReport } from '../core/check.js';
import type { DoctorReport } from '../core/doctor.js';

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
