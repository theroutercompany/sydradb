import { existsSync } from "node:fs";

import { afterEach, describe, expect, test } from "vitest";

import { findRepoRoot, resolveSydraBinary } from "./paths.js";
import { TradingShowcaseSessionManager } from "./sessionManager.js";

const repoRoot = findRepoRoot();
const binaryPath = resolveSydraBinary(repoRoot);

describe("TradingShowcaseSessionManager", () => {
  const runIfBinary = existsSync(binaryPath) ? test : test.skip;
  let manager: TradingShowcaseSessionManager | null = null;

  afterEach(async () => {
    if (manager) {
      await manager.close();
      manager = null;
    }
  });

  runIfBinary("coalesces concurrent getState calls", async () => {
    manager = new TradingShowcaseSessionManager();
    const [a, b] = await Promise.all([manager.getState(), manager.getState()]);
    expect(a.sessionId).toBe(b.sessionId);
  });

  runIfBinary("detects the trading market-data capability floor", async () => {
    manager = new TradingShowcaseSessionManager();
    const state = await manager.reset();
    expect(state.capabilities["market.http"]).toBe(true);
    expect(state.capabilities["trading.analysis"]).toBe(true);
  });
});
