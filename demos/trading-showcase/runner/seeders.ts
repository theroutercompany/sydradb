import fs from "node:fs/promises";
import path from "node:path";

import { type ScenarioSandbox, cleanupSandbox, createSandbox, createWorkspace } from "./runtime.js";
import { fixturesDir } from "./paths.js";

type SeedRoutine = (rootDir: string, binaryPath: string) => Promise<ScenarioSandbox>;
type CleanupRoutine = (sandbox: ScenarioSandbox, preserveArtifacts?: boolean) => Promise<void>;

const tradingFixtureDir = path.join(fixturesDir, "market-data");
const baselineFixture = path.join(tradingFixtureDir, "baseline.ndjson");
const correctedFixture = path.join(tradingFixtureDir, "corrected.ndjson");
const revisionBaselineFixture = path.join(tradingFixtureDir, "revision-baseline.ndjson");
const revisionCorrectedFixture = path.join(tradingFixtureDir, "revision-corrected.ndjson");

async function createTradingSandbox(
  rootDir: string,
  configOverrides: Parameters<typeof createWorkspace>[3],
): Promise<ScenarioSandbox> {
  const workspace = await createWorkspace(rootDir, "trading-desk", "compiled", configOverrides);
  const sandbox = createSandbox(rootDir, {
    "trading-desk": workspace,
  });
  sandbox.vars.baseline_ndjson = await fs.readFile(baselineFixture, "utf8");
  sandbox.vars.corrected_ndjson = await fs.readFile(correctedFixture, "utf8");
  sandbox.vars.revision_baseline_ndjson = await fs.readFile(revisionBaselineFixture, "utf8");
  sandbox.vars.revision_corrected_ndjson = await fs.readFile(revisionCorrectedFixture, "utf8");
  return sandbox;
}

export const seedRoutines: Record<string, SeedRoutine> = {
  async seedTradingFeed(rootDir) {
    return createTradingSandbox(rootDir, {
      casMode: "off",
      metadataReadMode: "legacy",
    });
  },

  async seedTradingDefinitions(rootDir) {
    return createTradingSandbox(rootDir, {
      casMode: "off",
      metadataReadMode: "legacy",
    });
  },

  async seedTradingAnalysis(rootDir) {
    return createTradingSandbox(rootDir, {
      casMode: "dual_write",
      metadataReadMode: "primary",
    });
  },
};

export const cleanupRoutines: Record<string, CleanupRoutine> = {
  cleanupWorkspaceSandbox: cleanupSandbox,
};
