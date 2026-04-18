import type { Config } from '../../config/schema.js';
import { sha256 } from '../../utils/hash.js';
import { stableStringify } from '../../utils/json.js';
import type { SourceFile, SourceKey } from './schemas.js';

export function computeSourceHash(sourceKey: SourceKey): string {
  return `sha256:${sha256(stableStringify(sourceKey))}`;
}

export function computeConfigHash(config: Config): string {
  return `sha256:${sha256(stableStringify(config))}`;
}

export function computeSourceFileHash(source: SourceFile): string {
  return `sha256:${sha256(stableStringify(source))}`;
}

/**
 * Hashes only the provider-relevant subset of config that affects translation output.
 * Changes to glossary, model, provider type, or minimum version will bust cached entries.
 * Fields like target_locales or keys.scopes are intentionally excluded.
 */
export function computeProviderCacheKeyHash(config: Config): string {
  const cacheKeySubset = {
    codex_min_version: config.provider.codex_min_version,
    glossary: config.provider.glossary,
    ...(config.provider.model !== undefined ? { model: config.provider.model } : {}),
    type: config.provider.type,
  };
  return `sha256:${sha256(stableStringify(cacheKeySubset))}`;
}
