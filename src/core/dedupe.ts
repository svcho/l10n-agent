import type { Diagnostic } from './diagnostics.js';
import type { ProjectSnapshot } from './store/load.js';
import type { SemanticDedupeGroup as ProviderSemanticDedupeGroup, TranslationProvider } from '../providers/base.js';

export interface ExactDedupeGroup {
  keys: string[];
  text: string;
}

export interface SemanticDedupeGroup {
  canonical_key: string;
  confidence: number;
  duplicate_keys: string[];
  model_version: string;
  rationale: string;
}

export interface DedupeReport {
  diagnostics: Diagnostic[];
  exact_duplicates: ExactDedupeGroup[];
  ok: boolean;
  semantic_duplicates: SemanticDedupeGroup[];
  summary: {
    duplicate_keys: number;
    exact_duplicate_groups: number;
    semantic_duplicate_groups: number;
    source_keys: number;
  };
}

function buildExactDuplicates(snapshot: ProjectSnapshot): ExactDedupeGroup[] {
  const groups = new Map<string, string[]>();

  for (const [key, value] of Object.entries(snapshot.source.value.keys)) {
    const existing = groups.get(value.text) ?? [];
    existing.push(key);
    groups.set(value.text, existing);
  }

  return [...groups.entries()]
    .filter(([, keys]) => keys.length > 1)
    .map(([text, keys]) => ({
      keys: [...keys].sort(),
      text,
    }))
    .sort((left, right) => left.keys[0]!.localeCompare(right.keys[0]!));
}

function createExactDuplicateDiagnostic(group: ExactDedupeGroup): Diagnostic {
  return {
    code: 'L10N_E0070',
    details: {
      canonical_key: group.keys[0],
      duplicate_keys: group.keys.slice(1).join(', '),
    },
    level: 'warn',
    next: `Consider renaming ${group.keys.slice(1).join(', ')} to reuse ${group.keys[0]}.`,
    summary: 'Exact duplicate source copy exists under multiple keys',
  };
}

function createSemanticDuplicateDiagnostic(group: SemanticDedupeGroup): Diagnostic {
  return {
    code: 'L10N_E0071',
    details: {
      canonical_key: group.canonical_key,
      confidence: Number(group.confidence.toFixed(2)),
      duplicate_keys: group.duplicate_keys.join(', '),
      model_version: group.model_version,
    },
    level: 'warn',
    next: `Consider renaming ${group.duplicate_keys.join(', ')} to reuse ${group.canonical_key}.`,
    summary: group.rationale.length > 0 ? group.rationale : 'Provider found a semantic duplicate candidate',
  };
}

function normalizeSemanticGroups(
  sourceKeys: Set<string>,
  exactDuplicates: ExactDedupeGroup[],
  modelVersion: string,
  groups: ProviderSemanticDedupeGroup[],
): SemanticDedupeGroup[] {
  const exactMembership = new Map<string, string>();
  for (const group of exactDuplicates) {
    for (const key of group.keys) {
      exactMembership.set(key, group.text);
    }
  }

  const normalized = new Map<string, SemanticDedupeGroup>();
  for (const group of groups) {
    if (!sourceKeys.has(group.canonicalKey)) {
      continue;
    }

    const validDuplicateKeys = group.duplicateKeys.filter((key) => sourceKeys.has(key));
    if (validDuplicateKeys.length === 0) {
      continue;
    }

    const allKeys = [group.canonicalKey, ...validDuplicateKeys].sort();
    if (allKeys.length < 2) {
      continue;
    }

    const allExactMatch =
      exactMembership.has(allKeys[0]!) &&
      allKeys.every((key) => exactMembership.get(key) === exactMembership.get(allKeys[0]!));
    if (allExactMatch) {
      continue;
    }

    const dedupeKey = allKeys.join('|');
    normalized.set(dedupeKey, {
      canonical_key: group.canonicalKey,
      confidence: group.confidence,
      duplicate_keys: [...validDuplicateKeys].sort(),
      model_version: modelVersion,
      rationale: group.rationale.trim(),
    });
  }

  return [...normalized.values()].sort((left, right) =>
    left.canonical_key.localeCompare(right.canonical_key) ||
    left.duplicate_keys.join('|').localeCompare(right.duplicate_keys.join('|')),
  );
}

export async function buildDedupeReport(
  snapshot: ProjectSnapshot,
  provider?: TranslationProvider,
): Promise<DedupeReport> {
  const exactDuplicates = buildExactDuplicates(snapshot);
  const sourceKeys = new Set(Object.keys(snapshot.source.value.keys));
  const diagnostics: Diagnostic[] = exactDuplicates.map(createExactDuplicateDiagnostic);

  let semanticDuplicates: SemanticDedupeGroup[] = [];
  if (provider?.findSemanticDuplicates) {
    const result = await provider.findSemanticDuplicates({
      candidates: Object.entries(snapshot.source.value.keys)
        .map(([key, value]) => ({
          ...(value.description ? { description: value.description } : {}),
          key,
          text: value.text,
        }))
        .sort((left, right) => left.key.localeCompare(right.key)),
      sourceLocale: snapshot.config.source_locale,
    });

    semanticDuplicates = normalizeSemanticGroups(sourceKeys, exactDuplicates, result.modelVersion, result.groups);
    diagnostics.push(...semanticDuplicates.map(createSemanticDuplicateDiagnostic));
  }

  return {
    diagnostics,
    exact_duplicates: exactDuplicates,
    ok: true,
    semantic_duplicates: semanticDuplicates,
    summary: {
      duplicate_keys:
        exactDuplicates.reduce((sum, group) => sum + group.keys.length, 0) +
        semanticDuplicates.reduce((sum, group) => sum + 1 + group.duplicate_keys.length, 0),
      exact_duplicate_groups: exactDuplicates.length,
      semantic_duplicate_groups: semanticDuplicates.length,
      source_keys: Object.keys(snapshot.source.value.keys).length,
    },
  };
}
