import fs from "node:fs/promises";
import path from "node:path";

import type { DemoScenarioSummary, ScenarioAvailability, ScenarioManifest } from "../shared/contracts.js";
import { scenariosDir } from "./paths.js";
import { scenarioManifestSchema } from "./scenarioSchemas.js";

export async function loadScenarioManifests(): Promise<ScenarioManifest[]> {
  const entries = await fs.readdir(scenariosDir);
  const manifests: ScenarioManifest[] = [];

  for (const entry of entries.filter((name) => name.endsWith(".json")).sort()) {
    const filePath = path.join(scenariosDir, entry);
    const raw = await fs.readFile(filePath, "utf8");
    const parsed = JSON.parse(raw) as unknown;
    manifests.push(scenarioManifestSchema.parse(parsed));
  }

  return manifests;
}

export function buildScenarioAvailability(
  manifests: ScenarioManifest[],
  capabilities: Record<string, boolean>,
): ScenarioAvailability[] {
  return manifests.map((manifest) => {
    const missingCapabilities = manifest.requiredCapabilities.filter((capability) => !capabilities[capability]);
    return {
      id: manifest.id,
      available: missingCapabilities.length === 0,
      missingCapabilities,
    };
  });
}

export function buildScenarioSummaries(
  manifests: ScenarioManifest[],
  capabilities: Record<string, boolean>,
): DemoScenarioSummary[] {
  const availability = new Map(buildScenarioAvailability(manifests, capabilities).map((entry) => [entry.id, entry]));
  return manifests.map((manifest) => ({
    manifest,
    availability: availability.get(manifest.id) ?? {
      id: manifest.id,
      available: false,
      missingCapabilities: manifest.requiredCapabilities,
    },
  }));
}

