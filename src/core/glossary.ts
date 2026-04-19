import type { Diagnostic } from './diagnostics.js';
import type { ProjectSnapshot } from './store/load.js';

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function containsGlossaryTerm(text: string, term: string): boolean {
  if (term.trim().length === 0) {
    return true;
  }

  return new RegExp(`(?<!\\p{L})${escapeRegExp(term)}(?!\\p{L})`, 'u').test(text);
}

export function lintGlossary(snapshot: ProjectSnapshot): Diagnostic[] {
  const diagnostics: Diagnostic[] = [];

  for (const [sourceTerm, localizedTerms] of Object.entries(snapshot.config.provider.glossary)) {
    for (const translation of snapshot.translations) {
      const targetTerm = localizedTerms[translation.locale];
      if (!targetTerm || !translation.value) {
        continue;
      }

      for (const [key, sourceKey] of Object.entries(snapshot.source.value.keys)) {
        if (!containsGlossaryTerm(sourceKey.text, sourceTerm)) {
          continue;
        }

        const entry = translation.value.entries[key];
        if (!entry || entry.text.trim().length === 0) {
          continue;
        }

        if (containsGlossaryTerm(entry.text, targetTerm)) {
          continue;
        }

        diagnostics.push({
          code: 'L10N_E0087',
          details: {
            expected_term: targetTerm,
            key,
            locale: translation.locale,
            source_term: sourceTerm,
          },
          level: 'error',
          next: 'Update the translation manually or rerun sync so the glossary term is preserved.',
          summary: 'Translation does not preserve a configured glossary term',
        });
      }
    }
  }

  return diagnostics.sort((left, right) =>
    left.code.localeCompare(right.code) ||
    String(left.details?.locale ?? '').localeCompare(String(right.details?.locale ?? '')) ||
    String(left.details?.key ?? '').localeCompare(String(right.details?.key ?? '')),
  );
}
