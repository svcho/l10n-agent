import type { SourceKey } from './schemas.js';
import { sha256 } from '../../utils/hash.js';
import { stableStringify } from '../../utils/json.js';

export function computeSourceHash(sourceKey: SourceKey): string {
  return `sha256:${sha256(stableStringify(sourceKey))}`;
}
