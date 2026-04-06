import { existsSync } from "node:fs";

import { afterAll, describe, expect, test } from "vitest";

import { findRepoRoot, resolveSydraBinary } from "./paths.js";
import { TradingShowcaseSessionManager } from "./sessionManager.js";

const repoRoot = findRepoRoot();
const binaryPath = resolveSydraBinary(repoRoot);
const manager = new TradingShowcaseSessionManager();

afterAll(async () => {
  await manager.close();
});

describe("trading scenario runner", () => {
  const runIfBinary = existsSync(binaryPath) ? test : test.skip;

  runIfBinary("runs every available scenario end to end", async () => {
    const state = await manager.reset();

    for (const scenario of state.scenarios.filter((entry) => entry.availability.available)) {
      const result = await manager.runScenario(scenario.manifest.id);
      expect(result.status).toBe("passed");
      expect(result.steps.length).toBeGreaterThan(0);
    }
  }, 20_000);
});
