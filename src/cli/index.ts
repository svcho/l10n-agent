#!/usr/bin/env node
import process from 'node:process';
import { resolve } from 'node:path';

import { Command } from 'commander';

import { buildCheckReport } from '../core/check.js';
import type { Diagnostic } from '../core/diagnostics.js';
import { buildDoctorReport } from '../core/doctor.js';
import { lintSourceKeys } from '../core/linter/lint-keys.js';
import { loadProjectSnapshot } from '../core/store/load.js';
import { buildSyncPlan, runSync } from '../core/sync.js';
import { L10nError } from '../errors/l10n-error.js';
import { CodexLocalProvider, codexPreflight } from '../providers/codex-local.js';
import { printDiagnosticsReport, printDoctorReport, printSyncPlan, printSyncReport } from './output.js';

interface GlobalOptions {
  color: boolean;
  config: string | undefined;
  cwd: string;
  json: boolean;
  verbose: boolean;
}

function getGlobalOptions(command: Command): GlobalOptions {
  const options = command.optsWithGlobals<GlobalOptions>();
  return {
    color: options.color ?? true,
    config: options.config,
    cwd: resolve(options.cwd ?? process.cwd()),
    json: options.json ?? false,
    verbose: options.verbose ?? false,
  };
}

function printFatalError(error: unknown, options: Pick<GlobalOptions, 'json' | 'verbose'>): void {
  if (error instanceof L10nError) {
    if (options.json) {
      process.stderr.write(`${JSON.stringify(error.diagnostic, null, 2)}\n`);
      return;
    }

    process.stderr.write(`error  ${error.diagnostic.code}  ${error.diagnostic.summary}\n`);
    for (const [key, value] of Object.entries(error.diagnostic.details ?? {})) {
      process.stderr.write(`       ${key}: ${String(value)}\n`);
    }
    if (error.diagnostic.next) {
      process.stderr.write(`       next: ${error.diagnostic.next}\n`);
    }
    return;
  }

  if (error instanceof Error) {
    process.stderr.write(`${error.message}\n`);
    if (options.verbose && error.stack) {
      process.stderr.write(`${error.stack}\n`);
    }
    return;
  }

  process.stderr.write('Unknown failure\n');
}

function getExitCodeForError(error: unknown): number {
  if (error instanceof L10nError) {
    if (['L10N_E0053', 'L10N_E0054', 'L10N_E0055'].includes(error.diagnostic.code)) {
      return 3;
    }

    return 1;
  }

  return 1;
}

async function runAction(command: Command, action: (options: GlobalOptions) => Promise<number>): Promise<void> {
  const options = getGlobalOptions(command);

  try {
    process.exitCode = await action(options);
  } catch (error) {
    printFatalError(error, options);
    process.exitCode = getExitCodeForError(error);
  }
}

function createProvider(options: GlobalOptions, minimumVersion: string, model?: string): CodexLocalProvider {
  return new CodexLocalProvider({
    cwd: options.cwd,
    minimumVersion,
    ...(model ? { model } : {}),
  });
}

const program = new Command();
program
  .name('l10n-agent')
  .description('Local-first CLI for canonical localization workflows.')
  .option('--config <path>', 'path to the config file')
  .option('--cwd <path>', 'working directory to operate from', process.cwd())
  .option('--json', 'emit machine-readable JSON output', false)
  .option('--no-color', 'disable ANSI colors')
  .option('--verbose', 'show extra error detail', false);

program
  .command('lint')
  .description('Validate canonical key names and source-level constraints.')
  .action(async function lintAction(this: Command) {
    await runAction(this, async (options) => {
      const snapshot = await loadProjectSnapshot(options.cwd, options.config);
      const diagnostics = lintSourceKeys(snapshot.config, snapshot.source.value);
      const report = {
        diagnostics,
        ok: diagnostics.length === 0,
        summary: {
          key_count: Object.keys(snapshot.source.value.keys).length,
        },
      };

      printDiagnosticsReport(report, options);
      return diagnostics.length === 0 ? 0 : 1;
    });
  });

program
  .command('check')
  .description('Run deterministic repo health checks for source and translations.')
  .option('--fast', 'reserved for later; currently same as the default check path', false)
  .action(async function checkAction(this: Command) {
    await runAction(this, async (options) => {
      const snapshot = await loadProjectSnapshot(options.cwd, options.config);
      const report = await buildCheckReport(snapshot);
      printDiagnosticsReport(report, options);
      return report.ok ? 0 : 1;
    });
  });

program
  .command('doctor')
  .description('Print repo health and provider preflight information without translation calls.')
  .action(async function doctorAction(this: Command) {
    await runAction(this, async (options) => {
      const snapshot = await loadProjectSnapshot(options.cwd, options.config);
      const provider = createProvider(
        options,
        snapshot.config.provider.codex_min_version,
        snapshot.config.provider.model,
      );
      const report = await buildDoctorReport(
        snapshot,
        () => codexPreflight(snapshot.config.provider.codex_min_version),
        provider.estimateRequests.bind(provider),
      );
      printDoctorReport(report, options);
      return 0;
    });
  });

program
  .command('sync')
  .description('Reconcile source, translations, cache, and platform files.')
  .option('--continue', 'resume only if a partial sync state exists', false)
  .option('--dry-run', 'compute the sync plan without writing files or calling the provider', false)
  .option('--locale <locale>', 'limit sync to one locale', (value, previous: string[] = []) => [...previous, value], [])
  .option('--strict', 'abort the run when a placeholder mismatch is detected', false)
  .action(async function syncAction(this: Command) {
    await runAction(this, async (options) => {
      const commandOptions = this.opts<{
        continue: boolean;
        dryRun: boolean;
        locale: string[];
        strict: boolean;
      }>();
      const snapshot = await loadProjectSnapshot(options.cwd, options.config);
      const provider = createProvider(
        options,
        snapshot.config.provider.codex_min_version,
        snapshot.config.provider.model,
      );
      const report = await runSync(snapshot, {
        continueOnly: commandOptions.continue,
        dryRun: commandOptions.dryRun,
        locales: commandOptions.locale,
        provider,
        strict: commandOptions.strict,
      });

      if (commandOptions.dryRun) {
        printSyncPlan(buildSyncPlan(snapshot, { locales: commandOptions.locale }), report, options);
      } else {
        printSyncReport(report, options);
      }

      return report.ok ? 0 : 1;
    });
  });

await program.parseAsync(process.argv);
