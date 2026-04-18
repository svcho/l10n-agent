import type { Diagnostic } from '../core/diagnostics.js';

export class L10nError extends Error {
  readonly diagnostic: Diagnostic;

  constructor(diagnostic: Diagnostic) {
    super(`${diagnostic.code}: ${diagnostic.summary}`);
    this.name = 'L10nError';
    this.diagnostic = diagnostic;
  }
}
