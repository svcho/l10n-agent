import type { ICUPlaceholder } from '../core/placeholders/types.js';

export interface TranslationRequest {
  description?: string;
  glossary?: Record<string, Record<string, string>>;
  placeholders: ICUPlaceholder[];
  sourceLocale: string;
  sourceText: string;
  targetLocale: string;
}

export interface TranslationResult {
  modelVersion: string;
  text: string;
}

export interface PreflightResult {
  code?: string;
  detectedVersion?: string;
  message?: string;
  ok: boolean;
}

export interface TranslationProvider {
  readonly id: string;

  estimateRequests?(
    inputs: TranslationRequest[],
  ): Promise<{ notes?: string; requests: number }>;
  preflight?(): Promise<PreflightResult>;
  translate(input: TranslationRequest): Promise<TranslationResult>;
}
