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
