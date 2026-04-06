import fs from "node:fs/promises";
import path from "node:path";

import { buildScenarioAvailability, buildScenarioSummaries } from "../../shared/runtime/scenarioRegistry.js";
import { scenariosDir } from "./paths.js";
import { scenarioManifestSchema } from "./scenarioSchemas.js";

export { buildScenarioAvailability, buildScenarioSummaries };

export async function loadScenarioManifests() {
  const entries = await fs.readdir(scenariosDir);
  return Promise.all(
    entries
      .filter((name) => name.endsWith(".json"))
      .sort()
      .map(async (entry) => {
        const raw = await fs.readFile(path.join(scenariosDir, entry), "utf8");
        return scenarioManifestSchema.parse(JSON.parse(raw) as unknown);
      }),
  );
}
