#!/usr/bin/env node
import process from 'node:process';
import { resolve } from 'node:path';

import { Command } from 'commander';

import { buildCheckReport } from '../core/check.js';
import { buildDedupeReport } from '../core/dedupe.js';
import type { Diagnostic } from '../core/diagnostics.js';
import { buildDoctorReport } from '../core/doctor.js';
import { lintGlossary } from '../core/glossary.js';
import { runImport } from '../core/import.js';
import { runInit } from '../core/init.js';
import { collectLintFixCandidates, runLintFix } from '../core/lint.js';
import { lintSourceKeys } from '../core/linter/lint-keys.js';
import { runRepair } from '../core/repair.js';
import { runRename } from '../core/rename.js';
import { runRollback } from '../core/rollback.js';
import { loadProjectSnapshot } from '../core/store/load.js';
import { buildSyncPlan, runSync } from '../core/sync.js';
import { L10nError } from '../errors/l10n-error.js';
import { CodexLocalProvider, codexPreflight } from '../providers/codex-local.js';
import {
  printDiagnosticsReport,
  printDedupeReport,
  printDoctorReport,
  printImportReport,
  printInitReport,
  printRenameReport,
  printRollbackReport,
  printSyncPlan,
  printSyncReport,
} from './output.js';

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
  .command('init')
  .description('Scaffold l10n/ config and canonical store files.')
  .option('--android-path <path>', 'relative path to Android strings.xml')
  .option('--ios-path <path>', 'relative path to iOS .xcstrings or Localizable.strings')
  .option('--import-from <source>', 'import existing strings from iOS (xcstrings/strings) or android')
  .option('--no-import-existing', 'skip importing existing platform strings')
  .option('--source-locale <locale>', 'canonical source locale', 'en')
  .option(
    '--target-locale <locale>',
    'target locale to scaffold',
    (value, previous: string[] = []) => [...previous, value],
    [],
  )
  .action(async function initAction(this: Command) {
    await runAction(this, async (options) => {
      const commandOptions = this.opts<{
        androidPath?: string;
        importExisting?: boolean;
        importFrom?: 'android' | 'xcstrings';
        iosPath?: string;
        sourceLocale?: string;
        targetLocale: string[];
      }>();
      const report = await runInit(options.cwd, options.config, {
        ...(commandOptions.androidPath ? { androidPath: commandOptions.androidPath } : {}),
        ...(commandOptions.importExisting !== undefined
          ? { importExisting: commandOptions.importExisting }
          : {}),
        ...(commandOptions.importFrom ? { importFrom: commandOptions.importFrom } : {}),
        ...(commandOptions.iosPath ? { iosPath: commandOptions.iosPath } : {}),
        ...(commandOptions.sourceLocale ? { sourceLocale: commandOptions.sourceLocale } : {}),
        ...(commandOptions.targetLocale.length > 0 ? { targetLocales: commandOptions.targetLocale } : {}),
      });

      printInitReport(report, options);
      return report.ok ? 0 : 1;
    });
  });

program
  .command('lint')
  .description('Validate canonical key names and source-level constraints.')
  .option('--fix', 'auto-rename invalid canonical keys and rewrite exact key references in repo text files', false)
  .option('--glossary', 'validate persisted translations against configured glossary terms', false)
  .action(async function lintAction(this: Command) {
    await runAction(this, async (options) => {
      const snapshot = await loadProjectSnapshot(options.cwd, options.config);
      const commandOptions = this.opts<{ fix: boolean; glossary: boolean }>();
      const diagnostics = [
        ...lintSourceKeys(snapshot.config, snapshot.source.value),
        ...(commandOptions.glossary ? lintGlossary(snapshot) : []),
      ];
      const candidates = collectLintFixCandidates(snapshot, diagnostics);
      const report = commandOptions.fix
        ? candidates.length === 0
          ? {
              diagnostics,
              fixed_renames: [],
              ok: diagnostics.length === 0,
              summary: {
                fixed_keys: 0,
                key_count: Object.keys(snapshot.source.value.keys).length,
                reference_files_touched: 0,
                reference_replacements: 0,
              },
            }
          : await (async () => {
              const provider = createProvider(
                options,
                snapshot.config.provider.codex_min_version,
                snapshot.config.provider.model,
              );
              const preflight = await provider.preflight();
              if (!preflight.ok) {
                throw new L10nError({
                  code: preflight.code ?? 'L10N_E0054',
                  details: preflight.detectedVersion
                    ? { detected_version: preflight.detectedVersion }
                    : {},
                  level: 'error',
                  next: preflight.message ?? 'Re-run the command after fixing the provider environment.',
                  summary: 'Provider preflight failed',
                });
              }

              return runLintFix(snapshot, {
                glossary: commandOptions.glossary,
                provider: {
                  planKeyRenames: provider.planKeyRenames.bind(provider),
                },
              });
            })()
        : {
            diagnostics,
            fixed_renames: [],
            ok: diagnostics.length === 0,
            summary: {
              fixed_keys: 0,
              key_count: Object.keys(snapshot.source.value.keys).length,
              reference_files_touched: 0,
              reference_replacements: 0,
            },
          };

      printDiagnosticsReport(report, options);
      return report.ok ? 0 : 1;
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
  .command('dedupe')
  .description('Flag exact and semantic duplicate source copy across canonical keys.')
  .action(async function dedupeAction(this: Command) {
    await runAction(this, async (options) => {
      const snapshot = await loadProjectSnapshot(options.cwd, options.config);
      const provider = createProvider(
        options,
        snapshot.config.provider.codex_min_version,
        snapshot.config.provider.model,
      );
      const preflight = await provider.preflight();
      if (!preflight.ok) {
        throw new L10nError({
          code: preflight.code ?? 'L10N_E0054',
          details: preflight.detectedVersion ? { detected_version: preflight.detectedVersion } : {},
          level: 'error',
          next: preflight.message ?? 'Re-run the command after fixing the provider environment.',
          summary: 'Provider preflight failed',
        });
      }

      const report = await buildDedupeReport(snapshot, provider);
      printDedupeReport(report, options);
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
  .command('rename')
  .description('Rename one canonical key across source, translations, and platform files.')
  .argument('<from>')
  .argument('<to>')
  .option('--dry-run', 'compute the rename result without writing files', false)
  .action(async function renameAction(this: Command, from: string, to: string) {
    await runAction(this, async (options) => {
      const snapshot = await loadProjectSnapshot(options.cwd, options.config);
      const report = await runRename(snapshot, {
        dryRun: this.opts<{ dryRun: boolean }>().dryRun,
        from,
        to,
      });
      printRenameReport(report, options);
      return report.ok ? 0 : 1;
    });
  });

program
  .command('rollback')
  .description('Restore tracked localization files to the state before a history entry.')
  .requiredOption('--to <history-id>', 'history id to roll back to')
  .action(async function rollbackAction(this: Command) {
    await runAction(this, async (options) => {
      const snapshot = await loadProjectSnapshot(options.cwd, options.config);
      const report = await runRollback(snapshot, this.opts<{ to: string }>());
      printRollbackReport(report, options);
      return report.ok ? 0 : 1;
    });
  });

program
  .command('import')
  .description('Import canonical source and translations from an existing platform format.')
  .requiredOption('--from <source>', 'import source: xcstrings (iOS) or android')
  .option('--dry-run', 'compute the import result without writing files', false)
  .action(async function importAction(this: Command) {
    await runAction(this, async (options) => {
      const commandOptions = this.opts<{ dryRun: boolean; from: 'android' | 'xcstrings' }>();
      const snapshot = await loadProjectSnapshot(options.cwd, options.config);
      const report = await runImport(snapshot, commandOptions);
      printImportReport(report, options);
      return report.ok ? 0 : 1;
    });
  });

program
  .command('repair')
  .description('Re-canonicalize managed JSON files and auto-resolve simple merge artifacts.')
  .option('--dry-run', 'compute the repair result without writing files', false)
  .action(async function repairAction(this: Command) {
    await runAction(this, async (options) => {
      const report = await runRepair(options.cwd, options.config, this.opts<{ dryRun: boolean }>());
      printDiagnosticsReport(report, options);
      return report.ok ? 0 : 1;
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
