import type { DemoStateResponse, ScenarioRunResult } from "../../shared/contracts.js";

async function readJson<T>(response: Response): Promise<T> {
  if (!response.ok) {
    throw new Error(`Request failed: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as T;
}

export async function fetchState(): Promise<DemoStateResponse> {
  return readJson<DemoStateResponse>(await fetch("/api/demo/state"));
}

export async function resetSession(): Promise<DemoStateResponse> {
  return readJson<DemoStateResponse>(
    await fetch("/api/demo/session/reset", {
      method: "POST",
    }),
  );
}

export async function runScenario(scenarioId: string): Promise<ScenarioRunResult> {
  return readJson<ScenarioRunResult>(
    await fetch(`/api/demo/scenarios/${scenarioId}/run`, {
      method: "POST",
    }),
  );
}
