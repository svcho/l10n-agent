import type { Config, KeyCase } from '../../config/schema.js';
import { containsPluralSyntax } from '../placeholders/icu.js';
import type { Diagnostic } from '../diagnostics.js';
import type { SourceFile } from '../store/schemas.js';

const KEY_CASE_PATTERNS: Record<KeyCase, RegExp> = {
  'dotted.lower': /^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)*$/,
  kebab: /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/,
  screaming_snake: /^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*$/,
  snake: /^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$/,
};

function splitKeySegments(key: string, keyCase: KeyCase): string[] {
  switch (keyCase) {
    case 'dotted.lower':
      return key.split('.');
    case 'snake':
    case 'screaming_snake':
      return key.split('_');
    case 'kebab':
      return key.split('-');
  }
}

export function lintSourceKeys(config: Config, source: SourceFile): Diagnostic[] {
  const diagnostics: Diagnostic[] = [];

  for (const [key, value] of Object.entries(source.keys)) {
    const keyPattern = KEY_CASE_PATTERNS[config.keys.case];
    const segments = splitKeySegments(key, config.keys.case);
    const firstSegment = segments[0];

    if (!keyPattern.test(key)) {
      diagnostics.push({
        code: 'L10N_E0020',
        details: { expected: config.keys.case, key },
        level: 'error',
        next: 'Rename the key so it matches the configured casing convention.',
        summary: 'Key violates the configured case style',
      });
    }

    if (segments.length > config.keys.max_depth) {
      diagnostics.push({
        code: 'L10N_E0021',
        details: { key, max_depth: config.keys.max_depth, actual_depth: segments.length },
        level: 'error',
        next: 'Flatten the key or raise keys.max_depth in the config.',
        summary: 'Key exceeds the configured maximum depth',
      });
    }

    if (config.keys.scopes.length > 0 && firstSegment && !config.keys.scopes.includes(firstSegment)) {
      diagnostics.push({
        code: 'L10N_E0022',
        details: {
          key,
          scope: firstSegment,
          scopes: config.keys.scopes.join(', '),
        },
        level: 'error',
        next: 'Rename the key to use one of the configured scopes or update keys.scopes.',
        summary: 'Key uses a scope outside the configured whitelist',
      });
    }

    const forbiddenPrefix = config.keys.forbidden_prefixes.find((prefix) => key.startsWith(prefix));
    if (forbiddenPrefix) {
      diagnostics.push({
        code: 'L10N_E0023',
        details: { key, prefix: forbiddenPrefix },
        level: 'error',
        next: 'Rename the key so it no longer starts with the forbidden prefix.',
        summary: 'Key uses a forbidden prefix',
      });
    }

    if (containsPluralSyntax(value.text)) {
      diagnostics.push({
        code: 'L10N_E0042',
        details: { key },
        level: 'error',
        next: 'Remove plural ICU syntax for now; plural support is planned for a later milestone.',
        summary: 'Plural ICU syntax is not supported in v1',
      });
    }
  }

  return diagnostics.sort((left, right) => left.code.localeCompare(right.code));
}
