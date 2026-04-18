export type DiagnosticLevel = 'error' | 'warn' | 'info';

export interface Diagnostic {
  code: string;
  summary: string;
  level: DiagnosticLevel;
  details?: Record<string, string | number | boolean | undefined>;
  next?: string;
}

export function compareDiagnostics(left: Diagnostic, right: Diagnostic): number {
  return left.code.localeCompare(right.code) || left.summary.localeCompare(right.summary);
}

export function hasErrorDiagnostics(diagnostics: Diagnostic[]): boolean {
  return diagnostics.some((diagnostic) => diagnostic.level === 'error');
}
