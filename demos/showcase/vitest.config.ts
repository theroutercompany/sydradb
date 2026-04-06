import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["runner/**/*.test.ts", "ui/src/**/*.test.tsx"],
    environmentMatchGlobs: [
      ["ui/src/**/*.test.tsx", "jsdom"],
      ["runner/**/*.test.ts", "node"],
    ],
    setupFiles: ["./ui/src/testSetup.ts"],
    testTimeout: 120_000,
  },
});
