import { z } from 'zod';

import { LocaleCode } from '../core/store/schemas.js';

export const KeyCaseSchema = z.enum(['dotted.lower', 'snake', 'kebab', 'screaming_snake']);

export const KeyTransformSchema = z.enum(['identity', 'snake_case', 'kebab-case']);

export const PlatformConfigSchema = z.object({
  enabled: z.boolean().default(true),
  key_transform: KeyTransformSchema.default('identity'),
  path: z.string().min(1),
});

export const ProviderConfigSchema = z.object({
  codex_min_version: z.string().default('0.30.0'),
  glossary: z.record(z.string(), z.record(LocaleCode, z.string())).default({}),
  model: z.string().optional(),
  type: z.literal('codex-local'),
});

export const ConfigSchema = z
  .object({
    keys: z.object({
      case: KeyCaseSchema.default('dotted.lower'),
      forbidden_prefixes: z.array(z.string()).default([]),
      max_depth: z.number().int().min(1).max(10).default(4),
      scopes: z.array(z.string()).default([]),
    }),
    platforms: z.object({
      android: PlatformConfigSchema.optional(),
      ios: PlatformConfigSchema.optional(),
    }),
    provider: ProviderConfigSchema,
    source_locale: LocaleCode,
    target_locales: z.array(LocaleCode).min(1),
    version: z.literal(1).default(1),
  })
  .superRefine((config, ctx) => {
    if (config.target_locales.includes(config.source_locale)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'target_locales must not include source_locale',
        path: ['target_locales'],
      });
    }

    if (!config.platforms.ios && !config.platforms.android) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'at least one platform must be configured',
        path: ['platforms'],
      });
    }
  });

export type Config = z.infer<typeof ConfigSchema>;
export type KeyCase = z.infer<typeof KeyCaseSchema>;
export type KeyTransform = z.infer<typeof KeyTransformSchema>;
