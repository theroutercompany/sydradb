import path from "node:path";

import type { ScenarioSandbox } from "./runtime.js";
import { fixturesDir } from "./paths.js";
import {
  cleanupSandbox,
  createSandbox,
  createWorkspace,
  runBinary,
  runCasJson,
  seedWorkspaceFromFixtures,
  startWorkspaceServer,
  stopWorkspaceServer,
  warmWorkspace,
} from "./runtime.js";

type SeedRoutine = (rootDir: string, binaryPath: string) => Promise<ScenarioSandbox>;
type CleanupRoutine = (sandbox: ScenarioSandbox, preserveArtifacts?: boolean) => Promise<void>;

const edgeIncidentDir = path.join(fixturesDir, "edge-incident");
const eastBaseline = path.join(edgeIncidentDir, "edge-east-baseline.ndjson");
const eastIncident = path.join(edgeIncidentDir, "edge-east-incident.ndjson");
const westBaseline = path.join(edgeIncidentDir, "edge-west-baseline.ndjson");

async function seedEdgeIncidentBase(
  rootDir: string,
  binaryPath: string,
  compilerMode: "compiled" | "legacy" | "shadow" = "compiled",
): Promise<ScenarioSandbox> {
  const east = await createWorkspace(rootDir, "edge-east", compilerMode);
  const west = await createWorkspace(rootDir, "edge-west", compilerMode);
  const hq = await createWorkspace(rootDir, "hq", compilerMode);
  await seedWorkspaceFromFixtures(east, binaryPath, [eastBaseline]);
  await seedWorkspaceFromFixtures(west, binaryPath, [westBaseline]);
  await warmWorkspace(hq, binaryPath);
  return createSandbox(rootDir, {
    "edge-east": east,
    "edge-west": west,
    hq,
  });
}

export const seedRoutines: Record<string, SeedRoutine> = {
  async seedCasHistory(rootDir, binaryPath) {
    const sandbox = await seedEdgeIncidentBase(rootDir, binaryPath);
    const east = sandbox.workspaces["edge-east"];

    const refs = (await runCasJson(east, binaryPath, ["refs"])) as {
      entries: Array<{ name: string; id: string }>;
    };
    const main = refs.entries.find((entry) => entry.name === "heads/main");
    if (!main) {
      throw new Error("Expected heads/main to exist before capturing the baseline commit");
    }
    sandbox.vars.checkpoint_ref = main.id;
    await seedWorkspaceFromFixtures(east, binaryPath, [eastIncident]);
    return sandbox;
  },

  async seedCasSync(rootDir, binaryPath) {
    const sandbox = await seedEdgeIncidentBase(rootDir, binaryPath);
    const east = sandbox.workspaces["edge-east"];
    await seedWorkspaceFromFixtures(east, binaryPath, [eastIncident]);

    const cloneTarget = await createWorkspace(rootDir, "clone-target");
    const fetchTarget = await createWorkspace(rootDir, "fetch-target");
    const pushTarget = await createWorkspace(rootDir, "push-target");
    await warmWorkspace(fetchTarget, binaryPath);
    await warmWorkspace(pushTarget, binaryPath);

    sandbox.workspaces["clone-target"] = cloneTarget;
    sandbox.workspaces["fetch-target"] = fetchTarget;
    sandbox.workspaces["push-target"] = pushTarget;
    sandbox.vars.clone_target_dir = cloneTarget.dir;
    sandbox.vars.clone_target_data_dir = cloneTarget.dataDir;
    sandbox.vars.fetch_target_dir = fetchTarget.dir;
    sandbox.vars.fetch_target_data_dir = fetchTarget.dataDir;
    sandbox.vars.push_target_dir = pushTarget.dir;
    sandbox.vars.push_target_data_dir = pushTarget.dataDir;
    sandbox.vars.edge_east_dir = east.dir;
    sandbox.vars.edge_east_data_dir = east.dataDir;
    sandbox.vars.edge_west_dir = sandbox.workspaces["edge-west"].dir;
    sandbox.vars.edge_west_data_dir = sandbox.workspaces["edge-west"].dataDir;
    sandbox.vars.bundle_dir = path.join(rootDir, "bundle-output");
    return sandbox;
  },

  async seedCasMaintenance(rootDir, binaryPath) {
    const sandbox = await seedEdgeIncidentBase(rootDir, binaryPath);
    await seedWorkspaceFromFixtures(sandbox.workspaces["edge-east"], binaryPath, [eastIncident]);
    return sandbox;
  },

  async seedSydraqlQuery(rootDir, binaryPath) {
    const sandbox = await seedEdgeIncidentBase(rootDir, binaryPath);
    await startWorkspaceServer(sandbox.workspaces["edge-east"], binaryPath);
    return sandbox;
  },

  async seedSydraqlCompiler(rootDir, binaryPath) {
    const compiled = await createWorkspace(rootDir, "compiled", "compiled");
    const shadow = await createWorkspace(rootDir, "shadow", "shadow");
    const legacy = await createWorkspace(rootDir, "legacy", "legacy");

    await seedWorkspaceFromFixtures(compiled, binaryPath, [eastBaseline]);
    await seedWorkspaceFromFixtures(shadow, binaryPath, [eastBaseline]);
    await seedWorkspaceFromFixtures(legacy, binaryPath, [eastBaseline]);

    await startWorkspaceServer(compiled, binaryPath);
    await startWorkspaceServer(shadow, binaryPath);
    await startWorkspaceServer(legacy, binaryPath);

    return createSandbox(rootDir, {
      compiled,
      shadow,
      legacy,
    });
  },

  async seedEngineLifecycle(rootDir, binaryPath) {
    return seedEdgeIncidentBase(rootDir, binaryPath);
  },

  async seedMultiWriterHeadsPlaceholder(rootDir) {
    return createSandbox(rootDir, {});
  },
};

export const cleanupRoutines: Record<string, CleanupRoutine> = {
  cleanupWorkspaceSandbox: cleanupSandbox,
};
