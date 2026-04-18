import type { Diagnostic } from './diagnostics.js';
import type { ProjectSnapshot } from './store/load.js';

export interface DedupeGroup {
  keys: string[];
  text: string;
}

export interface DedupeReport {
  diagnostics: Diagnostic[];
  exact_duplicates: DedupeGroup[];
  ok: boolean;
  summary: {
    duplicate_groups: number;
    duplicate_keys: number;
    source_keys: number;
  };
}

export function buildDedupeReport(snapshot: ProjectSnapshot): DedupeReport {
  const groups = new Map<string, string[]>();

  for (const [key, value] of Object.entries(snapshot.source.value.keys)) {
    const existing = groups.get(value.text) ?? [];
    existing.push(key);
    groups.set(value.text, existing);
  }

  const exactDuplicates = [...groups.entries()]
    .filter(([, keys]) => keys.length > 1)
    .map(([text, keys]) => ({
      keys: [...keys].sort(),
      text,
    }))
    .sort((left, right) => left.keys[0]!.localeCompare(right.keys[0]!));

  const diagnostics: Diagnostic[] = exactDuplicates.map((group) => ({
    code: 'L10N_E0068',
    details: {
      canonical_key: group.keys[0],
      duplicate_keys: group.keys.slice(1).join(', '),
    },
    level: 'warn',
    next: `Consider renaming ${group.keys.slice(1).join(', ')} to reuse ${group.keys[0]}.`,
    summary: 'Exact duplicate source copy exists under multiple keys',
  }));

  return {
    diagnostics,
    exact_duplicates: exactDuplicates,
    ok: true,
    summary: {
      duplicate_groups: exactDuplicates.length,
      duplicate_keys: exactDuplicates.reduce((sum, group) => sum + group.keys.length, 0),
      source_keys: Object.keys(snapshot.source.value.keys).length,
    },
  };
}
