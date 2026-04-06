import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";

import { afterAll, describe, expect, test } from "vitest";

import { ShowcaseSessionManager } from "./sessionManager.js";
import { fixturesDir, findRepoRoot, resolveSydraBinary } from "./paths.js";

const repoRoot = findRepoRoot();
const binaryPath = resolveSydraBinary(repoRoot);
const manager = new ShowcaseSessionManager();

afterAll(async () => {
  await manager.close();
});

describe("scenario runner", () => {
  const runIfBinary = existsSync(binaryPath) ? test : test.skip;

  runIfBinary("runs every available non-experimental scenario end to end", async () => {
    const state = await manager.reset();
    const stableExpected = new Map<string, string>([
      ["sydraql-query", path.join(fixturesDir, "expected", "sydraql-query.json")],
      ["engine-lifecycle", path.join(fixturesDir, "expected", "engine-lifecycle.json")],
    ]);

    for (const scenario of state.scenarios.filter(
      (entry) => entry.availability.available && entry.manifest.maturity !== "experimental",
    )) {
      const result = await manager.runScenario(scenario.manifest.id);
      expect(result.status).toBe("passed");
      expect(result.steps.length).toBeGreaterThan(0);

      const fixturePath = stableExpected.get(result.scenarioId);
      if (fixturePath) {
        const expected = JSON.parse(await readFile(fixturePath, "utf8")) as Record<string, unknown>;
        expect(result.summaryEvidence).toEqual(expected);
      }
    }
  });

  runIfBinary("blocks the reserved multi-writer scenario when the capability is missing", async () => {
    await manager.reset();
    const result = await manager.runScenario("multi-writer-heads");
    expect(result.status).toBe("blocked");
    expect(result.steps).toHaveLength(0);
  });
});
