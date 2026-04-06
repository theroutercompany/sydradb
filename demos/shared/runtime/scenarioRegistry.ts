import type { DemoScenarioSummary, ScenarioAvailability, ScenarioManifest } from "./contracts.js";

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
