import { z } from 'zod';

export const LocaleCode = z.string().regex(/^[a-z]{2}(-[A-Z]{2})?$/);

export const PlaceholderSchema = z.object({
  example: z.string().optional(),
  type: z.enum(['string', 'number', 'date']),
});

export const SourceKeySchema = z.object({
  description: z.string().optional(),
  placeholders: z.record(z.string(), PlaceholderSchema).default({}),
  text: z.string().min(1),
});

export const SourceFileSchema = z.object({
  keys: z.record(z.string(), SourceKeySchema),
  version: z.literal(1),
});

export const TranslationEntrySchema = z.object({
  model_version: z.string(),
  provider: z.string(),
  reviewed: z.boolean().default(false),
  source_hash: z.string().regex(/^sha256:[0-9a-f]{64}$/),
  stale: z.boolean().default(false),
  text: z.string(),
  translated_at: z.string().datetime(),
});

export const TranslationFileSchema = z.object({
  entries: z.record(z.string(), TranslationEntrySchema),
  locale: LocaleCode,
  version: z.literal(1),
});

export const CacheFileSchema = z.object({
  entries: z.record(
    z.string(),
    z.object({
      cached_at: z.string().datetime(),
      text: z.string(),
    }),
  ),
  version: z.literal(1),
});

export const SyncStateFileSchema = z.object({
  batch_index: z.number().int().min(0),
  completed_translations: z.number().int().min(0),
  current_key: z.string().min(1).optional(),
  current_locale: LocaleCode.optional(),
  last_processed_key: z.string().min(1).optional(),
  last_processed_locale: LocaleCode.optional(),
  pid: z.number().int().positive().optional(),
  started_at: z.string().datetime(),
  total_translations: z.number().int().min(0),
  updated_at: z.string().datetime(),
  version: z.literal(1),
});

export const HistoryEntrySchema = z.discriminatedUnion('op', [
  z.object({
    actor: z.string(),
    id: z.string(),
    op: z.literal('init'),
    summary: z.string(),
    ts: z.string().datetime(),
  }),
  z.object({
    actor: z.string(),
    id: z.string(),
    op: z.literal('sync'),
    summary: z.string(),
    ts: z.string().datetime(),
  }),
  z.object({
    actor: z.string(),
    from: z.string(),
    id: z.string(),
    op: z.literal('import'),
    summary: z.string(),
    ts: z.string().datetime(),
  }),
  z.object({
    actor: z.string(),
    after: z.string(),
    before: z.string(),
    id: z.string(),
    op: z.literal('rename'),
    ts: z.string().datetime(),
  }),
  z.object({
    actor: z.string(),
    files_updated: z.number().int().min(0),
    id: z.string(),
    op: z.literal('lint_fix'),
    renames: z.array(
      z.object({
        after: z.string(),
        before: z.string(),
      }),
    ),
    ts: z.string().datetime(),
  }),
  z.object({
    actor: z.string(),
    id: z.string(),
    key: z.string(),
    op: z.literal('delete'),
    ts: z.string().datetime(),
  }),
  z.object({
    actor: z.string(),
    id: z.string(),
    locale: LocaleCode,
    op: z.literal('add_locale'),
    ts: z.string().datetime(),
  }),
  z.object({
    actor: z.string(),
    id: z.string(),
    locale: LocaleCode,
    op: z.literal('remove_locale'),
    ts: z.string().datetime(),
  }),
  z.object({
    actor: z.string(),
    id: z.string(),
    op: z.literal('repair'),
    summary: z.string(),
    ts: z.string().datetime(),
  }),
  z.object({
    actor: z.string(),
    id: z.string(),
    op: z.literal('rollback'),
    to: z.string(),
    ts: z.string().datetime(),
  }),
]);

export const HistoryFileSchema = z.array(HistoryEntrySchema);

export type CacheFile = z.infer<typeof CacheFileSchema>;
export type HistoryEntry = z.infer<typeof HistoryEntrySchema>;
export type LocaleCode = z.infer<typeof LocaleCode>;
export type Placeholder = z.infer<typeof PlaceholderSchema>;
export type SourceFile = z.infer<typeof SourceFileSchema>;
export type SourceKey = z.infer<typeof SourceKeySchema>;
export type SyncStateFile = z.infer<typeof SyncStateFileSchema>;
export type TranslationEntry = z.infer<typeof TranslationEntrySchema>;
export type TranslationFile = z.infer<typeof TranslationFileSchema>;
