import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "jsdom",
    setupFiles: ["./ui/src/testSetup.ts"],
    include: ["./runner/**/*.test.ts", "./ui/src/**/*.test.tsx"],
  },
});
