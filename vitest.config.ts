import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: [
      'packages/*/src/**/*.test.ts',
      'cli/src/**/*.test.ts',
    ],
    pool: 'forks',
    singleFork: true,
  },
});
