import { existsSync } from "node:fs";
import { rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { describe, expect, test } from "vitest";

import { fixturesDir, findRepoRoot, resolveSydraBinary } from "./paths.js";
import { createWorkspace, runBinary, seedWorkspaceFromFixtures, startWorkspaceServer } from "./runtime.js";

const repoRoot = findRepoRoot();
const binaryPath = resolveSydraBinary(repoRoot);
const baselineFixture = path.join(fixturesDir, "edge-incident", "edge-east-baseline.ndjson");

describe("runtime seeding", () => {
  const runIfBinary = existsSync(binaryPath) ? test : test.skip;

  runIfBinary("waits for seeded CAS metadata to settle before shutdown", async () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const rootDir = path.join(os.tmpdir(), `sydra-showcase-runtime-${Date.now()}-${attempt}`);
      const workspace = await createWorkspace(rootDir, "seed-check");
      try {
        await seedWorkspaceFromFixtures(workspace, binaryPath, [baselineFixture]);

        const logResult = await runBinary(workspace, binaryPath, ["cas", "--json", "log"]);
        const fsckResult = await runBinary(workspace, binaryPath, ["cas", "--json", "fsck", "--connectivity-only"]);

        expect(JSON.parse(logResult.stdout)).toMatchObject({ command: "log" });
        expect(JSON.parse(fsckResult.stdout)).toMatchObject({ command: "fsck" });
      } finally {
        await rm(rootDir, { recursive: true, force: true });
      }
    }
  });

  test("cleans up failed server startups when the binary path is invalid", async () => {
    const rootDir = path.join(os.tmpdir(), `sydra-showcase-runtime-invalid-${Date.now()}`);
    const workspace = await createWorkspace(rootDir, "bad-binary");
    try {
      await expect(startWorkspaceServer(workspace, path.join(rootDir, "missing-sydradb"))).rejects.toThrow(
        /Failed to start bad-binary server/,
      );
      expect(workspace.server).toBeUndefined();
    } finally {
      await rm(rootDir, { recursive: true, force: true });
    }
  });
});
