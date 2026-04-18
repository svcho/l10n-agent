import type { ICUPlaceholder } from '../core/placeholders/types.js';

export interface CanonicalKeySet {
  keys: Map<
    string,
    {
      placeholders: ICUPlaceholder[];
      text: string;
    }
  >;
}

export interface Adapter {
  readonly platform: 'ios' | 'android';

  fromPlatformPlaceholder(native: string): ICUPlaceholder;
  read(path: string): Promise<CanonicalKeySet>;
  reverseTransformKey(platformKey: string): string;
  toPlatformPlaceholder(icu: ICUPlaceholder): string;
  transformKey(canonicalKey: string): string;
  write(path: string, keys: CanonicalKeySet, locale: string): Promise<void>;
}
