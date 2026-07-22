import { defineConfig } from 'vitest/config';

// Crypto/logic tests run in node; component tests (if added) opt into jsdom.
export default defineConfig({
  test: {
    environment: 'node',
    include: ['test/**/*.test.{ts,tsx}'],
  },
});
