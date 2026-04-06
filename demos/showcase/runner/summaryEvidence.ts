import type { ScenarioRunResult } from "../shared/contracts.js";

function findStep(result: ScenarioRunResult, id: string) {
  return result.steps.find((step) => step.id === id);
}

export function buildSummaryEvidence(result: ScenarioRunResult): Record<string, unknown> | undefined {
  switch (result.scenarioId) {
    case "sydraql-query": {
      const hostAvg = findStep(result, "host-average")?.output as {
        rows?: Array<[string, number]>;
        stats?: { execution_mode?: string; legacy_fallback?: boolean };
      };
      const powerWindow = findStep(result, "power-window")?.output as {
        rows?: Array<[number, number]>;
      };
      return {
        avgValue: hostAvg?.rows?.[0]?.[1],
        executionMode: hostAvg?.stats?.execution_mode,
        legacyFallback: hostAvg?.stats?.legacy_fallback,
        firstValue: powerWindow?.rows?.[0]?.[0],
        lastValue: powerWindow?.rows?.[0]?.[1],
      };
    }
    case "engine-lifecycle": {
      const afterRestart = findStep(result, "range-after-restart")?.output as Array<unknown>;
      const refs = findStep(result, "refs-after-compact")?.output as {
        entries?: Array<{ name: string }>;
      };
      return {
        pointCountAfterRestart: Array.isArray(afterRestart) ? afterRestart.length : 0,
        anchorRefPresent: refs?.entries?.some((entry) => entry.name === "heads/lifecycle-anchor") ?? false,
      };
    }
    default:
      return undefined;
  }
}
