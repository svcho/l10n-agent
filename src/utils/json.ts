export function sortValueDeep<T>(value: T): T {
  if (Array.isArray(value)) {
    return value.map((item) => sortValueDeep(item)) as T;
  }

  if (value && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>).sort(([left], [right]) =>
      left.localeCompare(right),
    );

    return Object.fromEntries(entries.map(([key, nested]) => [key, sortValueDeep(nested)])) as T;
  }

  return value;
}

export function stableStringify(value: unknown): string {
  return `${JSON.stringify(sortValueDeep(value), null, 2)}\n`;
}
