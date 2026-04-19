import { readdir } from 'node:fs/promises';
import { extname, join, relative } from 'node:path';

import type { Diagnostic } from './diagnostics.js';
import { compareDiagnostics, hasErrorDiagnostics } from './diagnostics.js';
import { lintGlossary } from './glossary.js';
import { createLintFixHistoryEntry, buildHistoryId } from './history.js';
import { lintSourceKeys } from './linter/lint-keys.js';
import {
  getManagedFilePathsWithExtras,
  snapshotManagedFiles,
  writeProjectFiles,
  type TranslationLocaleState,
} from './project-files.js';
import type { ProjectSnapshot } from './store/load.js';
import type { SourceFile, TranslationEntry } from './store/schemas.js';
import { appendHistoryEntries } from './store/write.js';
import { readTextFile, writeTextFileAtomic } from '../utils/fs.js';
import { acquireSyncLock } from '../utils/lock.js';
import type { KeyRenameCandidate, KeyRenamePlan, TranslationProvider } from '../providers/base.js';

const RENAMEABLE_LINT_CODES = new Set(['L10N_E0020', 'L10N_E0021', 'L10N_E0022', 'L10N_E0023']);
const DEFAULT_LINT_FIX_BATCH_SIZE = 25;
const NON_CODE_DIRECTORIES = new Set([
  '.git',
  '.next',
  '.snapshots',
  '.turbo',
  'build',
  'coverage',
  'dist',
  'node_modules',
]);
const TEXT_FILE_EXTENSIONS = new Set([
  '.c',
  '.cc',
  '.cpp',
  '.cs',
  '.h',
  '.hpp',
  '.java',
  '.js',
  '.json',
  '.jsx',
  '.kt',
  '.kts',
  '.m',
  '.mm',
  '.plist',
  '.properties',
  '.rb',
  '.scala',
  '.storyboard',
  '.strings',
  '.swift',
  '.ts',
  '.tsx',
  '.xib',
  '.xml',
  '.yaml',
  '.yml',
]);

export interface LintReport {
  diagnostics: Diagnostic[];
  fixed_renames: Array<{ from: string; rationale?: string; to: string }>;
  ok: boolean;
  summary: {
    fixed_keys: number;
    key_count: number;
    reference_files_touched: number;
    reference_replacements: number;
  };
}

export interface LintFixProgress {
  batch_candidates?: number;
  batch_index?: number;
  batch_total?: number;
  message: string;
  phase: 'applying' | 'planning' | 'rewriting';
}

interface TextFileRewrite {
  path: string;
  replacements: number;
  text: string;
}

function buildDiagnostics(snapshot: ProjectSnapshot, options: { glossary?: boolean }): Diagnostic[] {
  return [
    ...lintSourceKeys(snapshot.config, snapshot.source.value),
    ...(options.glossary ? lintGlossary(snapshot) : []),
  ].sort(compareDiagnostics);
}

function renameRecordKeys<T>(record: Record<string, T>, renameMap: ReadonlyMap<string, string>): Record<string, T> {
  return Object.fromEntries(
    Object.entries(record).map(([key, value]) => [renameMap.get(key) ?? key, value] as const),
  );
}

function getRenameableDiagnostics(diagnostics: Diagnostic[]): Diagnostic[] {
  return diagnostics.filter(
    (diagnostic) =>
      RENAMEABLE_LINT_CODES.has(diagnostic.code) &&
      typeof diagnostic.details?.key === 'string' &&
      diagnostic.details.key.length > 0,
  );
}

function isRenameableDiagnostic(diagnostic: Diagnostic): boolean {
  return (
    RENAMEABLE_LINT_CODES.has(diagnostic.code) &&
    typeof diagnostic.details?.key === 'string' &&
    diagnostic.details.key.length > 0
  );
}

function chunkItems<T>(items: T[], batchSize: number): T[][] {
  const chunks: T[][] = [];
  for (let index = 0; index < items.length; index += batchSize) {
    chunks.push(items.slice(index, index + batchSize));
  }

  return chunks;
}

export function collectLintFixCandidates(snapshot: ProjectSnapshot, diagnostics?: Diagnostic[]): KeyRenameCandidate[] {
  const renameableDiagnostics = getRenameableDiagnostics(diagnostics ?? buildDiagnostics(snapshot, {}));
  const grouped = new Map<string, Set<string>>();

  for (const diagnostic of renameableDiagnostics) {
    const key = String(diagnostic.details?.key);
    const codes = grouped.get(key) ?? new Set<string>();
    codes.add(diagnostic.code);
    grouped.set(key, codes);
  }

  return [...grouped.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .flatMap(([key, violations]) => {
      const sourceKey = snapshot.source.value.keys[key];
      if (!sourceKey) {
        return [];
      }

      return [
        {
          ...(sourceKey.description ? { description: sourceKey.description } : {}),
          key,
          text: sourceKey.text,
          violations: [...violations].sort(),
        } satisfies KeyRenameCandidate,
      ];
    });
}

function createProviderPlanDiagnostics(
  candidates: KeyRenameCandidate[],
  plans: KeyRenamePlan[],
): Diagnostic[] {
  const planBySource = new Map(plans.map((plan) => [plan.from, plan]));

  return candidates.flatMap((candidate) => {
    const plan = planBySource.get(candidate.key);
    if (plan?.to) {
      return [];
    }

    return [
      {
        code: 'L10N_E0072',
        details: {
          key: candidate.key,
          ...(plan?.skip_reason ? { reason: plan.skip_reason } : {}),
        },
        level: 'error',
        next:
          'Use `l10n-agent rename <from> <to>` for this key, or adjust the key rules so the destination becomes unambiguous.',
        summary: 'Lint autofix could not determine a safe destination key',
      } satisfies Diagnostic,
    ];
  });
}

function buildRenameDiagnostics(
  renames: Array<{ from: string; rationale?: string; to: string }>,
  snapshot: ProjectSnapshot,
): Diagnostic[] {
  const renameMap = new Map(renames.map((rename) => [rename.from, rename.to]));
  const destinationKeys = new Set(renames.map((rename) => rename.to));
  const destinationCounts = new Map<string, number>();
  const remainingSourceKeys = new Set(
    Object.keys(snapshot.source.value.keys).filter((key) => !renameMap.has(key)),
  );
  const diagnostics: Diagnostic[] = [];

  for (const rename of renames) {
    destinationCounts.set(rename.to, (destinationCounts.get(rename.to) ?? 0) + 1);
  }

  for (const rename of renames) {
    if (!(rename.from in snapshot.source.value.keys)) {
      diagnostics.push({
        code: 'L10N_E0073',
        details: { key: rename.from },
        level: 'error',
        next: 'Re-run lint after restoring the missing source key, or remove the stale autofix suggestion.',
        summary: 'Lint autofix referenced a source key that no longer exists',
      });
    }

    if (rename.from === rename.to) {
      diagnostics.push({
        code: 'L10N_E0074',
        details: { key: rename.from },
        level: 'error',
        next: 'Choose a different destination key that resolves the lint violations.',
        summary: 'Lint autofix proposed a no-op rename',
      });
    }

    if (remainingSourceKeys.has(rename.to)) {
      diagnostics.push({
        code: 'L10N_E0075',
        details: { from: rename.from, to: rename.to },
        level: 'error',
        next: 'Pick a destination key that does not collide with an existing canonical key.',
        summary: 'Lint autofix destination collides with an existing key',
      });
    }

    if ((destinationCounts.get(rename.to) ?? 0) > 1) {
      diagnostics.push({
        code: 'L10N_E0076',
        details: { to: rename.to },
        level: 'error',
        next: 'Use distinct destination keys for each autofixed source key.',
        summary: 'Lint autofix produced duplicate destination keys',
      });
    }
  }

  const nextSource: SourceFile = {
    ...snapshot.source.value,
    keys: renameRecordKeys(snapshot.source.value.keys, renameMap),
  };

  for (const diagnostic of lintSourceKeys(snapshot.config, nextSource)) {
    if (
      RENAMEABLE_LINT_CODES.has(diagnostic.code) &&
      typeof diagnostic.details?.key === 'string' &&
      destinationKeys.has(String(diagnostic.details.key))
    ) {
      diagnostics.push({
        ...diagnostic,
        code: 'L10N_E0077',
        next: 'Use `l10n-agent rename` for this key, or adjust the config so the autofix destination becomes valid.',
        summary: 'Lint autofix proposed a destination key that is still invalid',
      });
    }
  }

  return diagnostics.sort(compareDiagnostics);
}

function isCandidateTextFile(path: string): boolean {
  return TEXT_FILE_EXTENSIONS.has(extname(path).toLowerCase());
}

async function walkCandidateFiles(rootDir: string, l10nDir: string): Promise<string[]> {
  const l10nRelativePath = relative(rootDir, l10nDir);
  const paths: string[] = [];

  async function walk(currentDir: string): Promise<void> {
    const entries = await readdir(currentDir, { withFileTypes: true });

    for (const entry of entries) {
      const path = join(currentDir, entry.name);
      const relativePath = relative(rootDir, path);

      if (entry.isDirectory()) {
        if (
          NON_CODE_DIRECTORIES.has(entry.name) ||
          relativePath === l10nRelativePath ||
          relativePath.startsWith(`${l10nRelativePath}/`)
        ) {
          continue;
        }

        await walk(path);
        continue;
      }

      if (entry.isFile() && isCandidateTextFile(path)) {
        paths.push(path);
      }
    }
  }

  await walk(rootDir);
  return paths.sort();
}

function rewriteTextReferences(
  content: string,
  renames: Array<{ from: string; to: string }>,
): { replacements: number; text: string } {
  let next = content;
  let replacements = 0;
  const tokens: Array<{ replacement: string; token: string }> = [];

  for (const [index, rename] of [...renames]
    .sort((left, right) => right.from.length - left.from.length || left.from.localeCompare(right.from))
    .entries()) {
    const parts = next.split(rename.from);
    if (parts.length === 1) {
      continue;
    }

    replacements += parts.length - 1;
    const token = `__L10N_AGENT_KEY_RENAME_${index}__`;
    tokens.push({ replacement: rename.to, token });
    next = parts.join(token);
  }

  for (const token of tokens) {
    next = next.split(token.token).join(token.replacement);
  }

  return { replacements, text: next };
}

async function collectReferenceRewrites(
  snapshot: ProjectSnapshot,
  renames: Array<{ from: string; to: string }>,
): Promise<TextFileRewrite[]> {
  const excludedPaths = new Set(getManagedFilePathsWithExtras(snapshot));
  const candidateFiles = await walkCandidateFiles(snapshot.rootDir, snapshot.l10nDir);
  const rewrites: TextFileRewrite[] = [];

  for (const filePath of candidateFiles) {
    if (excludedPaths.has(filePath)) {
      continue;
    }

    const sourceText = await readTextFile(filePath);
    if (sourceText.includes('\u0000')) {
      continue;
    }

    const rewritten = rewriteTextReferences(sourceText, renames);
    if (rewritten.replacements === 0 || rewritten.text === sourceText) {
      continue;
    }

    rewrites.push({
      path: filePath,
      replacements: rewritten.replacements,
      text: rewritten.text,
    });
  }

  return rewrites;
}

export async function runLintFix(
  snapshot: ProjectSnapshot,
  options: {
    batchSize?: number;
    glossary?: boolean;
    onProgress?: (progress: LintFixProgress) => void;
    provider: {
      planKeyRenames: NonNullable<TranslationProvider['planKeyRenames']>;
    };
  },
): Promise<LintReport> {
  const initialDiagnostics = buildDiagnostics(snapshot, options);
  const candidates = collectLintFixCandidates(snapshot, initialDiagnostics);

  if (candidates.length === 0) {
    return {
      diagnostics: initialDiagnostics,
      fixed_renames: [],
      ok: !hasErrorDiagnostics(initialDiagnostics),
      summary: {
        fixed_keys: 0,
        key_count: Object.keys(snapshot.source.value.keys).length,
        reference_files_touched: 0,
        reference_replacements: 0,
      },
    };
  }

  const candidateBatches = chunkItems(
    candidates,
    Math.max(1, options.batchSize ?? DEFAULT_LINT_FIX_BATCH_SIZE),
  );
  const providerPlans: KeyRenamePlan[] = [];

  for (const [batchIndex, batch] of candidateBatches.entries()) {
    options.onProgress?.({
      batch_candidates: batch.length,
      batch_index: batchIndex + 1,
      batch_total: candidateBatches.length,
      message: `Codex is planning key renames (${batchIndex + 1}/${candidateBatches.length}, ${batch.length} keys)`,
      phase: 'planning',
    });

    const providerResult = await options.provider.planKeyRenames({
      candidates: batch,
      forbiddenPrefixes: snapshot.config.keys.forbidden_prefixes,
      keyCase: snapshot.config.keys.case,
      maxDepth: snapshot.config.keys.max_depth,
      scopes: snapshot.config.keys.scopes,
      sourceLocale: snapshot.config.source_locale,
    });
    providerPlans.push(...providerResult.plans);
  }

  const renames = providerPlans
    .filter((plan): plan is { from: string; rationale?: string; to: string } => typeof plan.to === 'string')
    .sort((left, right) => left.from.localeCompare(right.from));
  const planningDiagnostics = [
    ...createProviderPlanDiagnostics(candidates, providerPlans),
    ...buildRenameDiagnostics(renames, snapshot),
  ].sort(compareDiagnostics);

  if (hasErrorDiagnostics(planningDiagnostics)) {
    return {
      diagnostics: [
        ...initialDiagnostics.filter((diagnostic) => !isRenameableDiagnostic(diagnostic)),
        ...planningDiagnostics,
      ].sort(compareDiagnostics),
      fixed_renames: [],
      ok: false,
      summary: {
        fixed_keys: 0,
        key_count: Object.keys(snapshot.source.value.keys).length,
        reference_files_touched: 0,
        reference_replacements: 0,
      },
    };
  }

  const renameMap = new Map(renames.map((rename) => [rename.from, rename.to]));
  const source: SourceFile = {
    ...snapshot.source.value,
    keys: renameRecordKeys(snapshot.source.value.keys, renameMap),
  };
  const translations: TranslationLocaleState[] = snapshot.translations.map((translation) => ({
    entries: renameRecordKeys<TranslationEntry>(translation.value?.entries ?? {}, renameMap),
    locale: translation.locale,
    path: translation.path,
  }));

  options.onProgress?.({
    message: `Applying ${renames.length} key rename${renames.length === 1 ? '' : 's'}`,
    phase: 'applying',
  });
  const referenceRewrites = await collectReferenceRewrites(snapshot, renames);

  options.onProgress?.({
    message: `Rewriting ${referenceRewrites.length} repo file${referenceRewrites.length === 1 ? '' : 's'} with key references`,
    phase: 'rewriting',
  });

  const lock = await acquireSyncLock(snapshot.l10nDir);
  try {
    const timestamp = new Date().toISOString();
    const historyId = buildHistoryId(timestamp, 'lintfix');
    await snapshotManagedFiles(
      snapshot.rootDir,
      snapshot.l10nDir,
      historyId,
      getManagedFilePathsWithExtras(
        snapshot,
        referenceRewrites.map((rewrite) => rewrite.path),
      ),
    );
    await writeProjectFiles(snapshot, source, translations);

    for (const rewrite of referenceRewrites) {
      await writeTextFileAtomic(rewrite.path, rewrite.text);
    }

    await appendHistoryEntries(snapshot.history.path, [
      createLintFixHistoryEntry(
        historyId,
        timestamp,
        renames.map((rename) => ({ after: rename.to, before: rename.from })),
        referenceRewrites.length,
      ),
    ]);
  } finally {
    await lock.release().catch(() => undefined);
  }

  const refreshedSnapshot: ProjectSnapshot = {
    ...snapshot,
    source: {
      ...snapshot.source,
      value: source,
    },
    translations: snapshot.translations.map((translation) => {
      const next = translations.find((candidate) => candidate.locale === translation.locale);
      if (!next) {
        return translation;
      }

      return {
        ...translation,
        exists: true,
        value: {
          entries: next.entries,
          locale: translation.locale,
          version: 1,
        },
      };
    }),
  };
  const diagnostics = buildDiagnostics(refreshedSnapshot, options);

  return {
    diagnostics,
    fixed_renames: renames,
    ok: !hasErrorDiagnostics(diagnostics),
    summary: {
      fixed_keys: renames.length,
      key_count: Object.keys(source.keys).length,
      reference_files_touched: referenceRewrites.length,
      reference_replacements: referenceRewrites.reduce(
        (count, rewrite) => count + rewrite.replacements,
        0,
      ),
    },
  };
}
