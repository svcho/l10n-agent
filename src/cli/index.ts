#!/usr/bin/env node
import process from 'node:process';
import { resolve } from 'node:path';

import { Command } from 'commander';

import { buildCheckReport } from '../core/check.js';
import type { Diagnostic } from '../core/diagnostics.js';
import { buildDoctorReport } from '../core/doctor.js';
import { lintSourceKeys } from '../core/linter/lint-keys.js';
import { loadProjectSnapshot } from '../core/store/load.js';
import { L10nError } from '../errors/l10n-error.js';
import { codexPreflight } from '../providers/codex-local.js';
import { printDiagnosticsReport, printDoctorReport } from './output.js';

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

async function runAction(command: Command, action: (options: GlobalOptions) => Promise<number>): Promise<void> {
  const options = getGlobalOptions(command);

  try {
    process.exitCode = await action(options);
  } catch (error) {
    printFatalError(error, options);
    process.exitCode = 1;
  }
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
      const report = await buildDoctorReport(snapshot, () =>
        codexPreflight(snapshot.config.provider.codex_min_version),
      );
      printDoctorReport(report, options);
      return 0;
    });
  });

await program.parseAsync(process.argv);
