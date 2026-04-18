import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    coverage: {
      exclude: ['dist/**', 'fixtures/**', 'vitest.config.ts'],
      provider: 'v8',
      reporter: ['text', 'html'],
    },
    environment: 'node',
    include: ['test/**/*.test.ts'],
  },
});
