import { existsSync } from "node:fs";

import { afterEach, describe, expect, test } from "vitest";

import { findRepoRoot, resolveSydraBinary } from "./paths.js";
import { ShowcaseSessionManager } from "./sessionManager.js";

const repoRoot = findRepoRoot();
const binaryPath = resolveSydraBinary(repoRoot);

describe("ShowcaseSessionManager", () => {
  const runIfBinary = existsSync(binaryPath) ? test : test.skip;
  let manager: ShowcaseSessionManager | null = null;

  afterEach(async () => {
    if (manager) {
      await manager.close();
      manager = null;
    }
  });

  runIfBinary("coalesces concurrent getState calls into one session", async () => {
    manager = new ShowcaseSessionManager();

    const [a, b, c] = await Promise.all([
      manager.getState(),
      manager.getState(),
      manager.getState(),
    ]);

    expect(a.sessionId).toBe(b.sessionId);
    expect(b.sessionId).toBe(c.sessionId);
  });

  runIfBinary("probes HTTP capability independently of compiler telemetry", async () => {
    manager = new ShowcaseSessionManager();

    const state = await manager.reset();

    expect(state.capabilities["sydraql.http"]).toBe(true);
  });
});
