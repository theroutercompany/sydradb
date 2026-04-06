import { readFile } from "node:fs/promises";
import path from "node:path";

import { describe, expect, test } from "vitest";

import { loadScenarioManifests } from "./scenarioRegistry.js";
import { scenariosDir } from "./paths.js";

describe("scenario registry", () => {
  test("loads and validates all manifests", async () => {
    const manifests = await loadScenarioManifests();
    expect(manifests.length).toBeGreaterThanOrEqual(6);
    expect(manifests.map((manifest) => manifest.id)).toContain("multi-writer-heads");
  });

  test("stores manifests as versioned JSON documents", async () => {
    const raw = await readFile(path.join(scenariosDir, "sydraql-query.json"), "utf8");
    const parsed = JSON.parse(raw) as { schemaVersion: number };
    expect(parsed.schemaVersion).toBe(1);
  });
});
