import type { KeyTransform } from '../../config/schema.js';
import type { CanonicalKeySet } from '../base.js';
import type { ExtendedCanonicalKeySet } from '../canonical.js';
import { IosStringsAdapter, isIosStringsPath } from './strings.js';
import { IosXcstringsAdapter } from './xcstrings.js';

export interface IosAdapter {
  inspect(path: string): Promise<{
    keyCount: number;
    locales: string[];
    sourceLanguage: string;
    version: string | null;
  }>;
  read(path: string, locale?: string): Promise<CanonicalKeySet>;
  readWithComments(path: string, locale?: string): Promise<ExtendedCanonicalKeySet>;
  write(path: string, keys: CanonicalKeySet, locale: string): Promise<void>;
}

export function createIosAdapter(
  path: string,
  options: {
    keyTransform?: KeyTransform;
    sourceLocale: string;
  },
): IosAdapter {
  return isIosStringsPath(path) ? new IosStringsAdapter(options) : new IosXcstringsAdapter(options);
}
