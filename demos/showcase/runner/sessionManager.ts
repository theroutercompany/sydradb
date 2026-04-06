import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";

import type { DemoStateResponse, ScenarioManifest, ScenarioRunResult } from "../shared/contracts.js";
import { buildScenarioAvailability, buildScenarioSummaries, loadScenarioManifests } from "./scenarioRegistry.js";
import { cleanupRoutines, seedRoutines } from "./seeders.js";
import { fixturesDir, findRepoRoot, resolveSydraBinary } from "./paths.js";
import {
  cleanupSandbox,
  createWorkspace,
  postSydraqlQuery,
  runBinary,
  seedWorkspaceFromFixtures,
  startWorkspaceServer,
  stopWorkspaceServer,
} from "./runtime.js";
import { runScenarioManifest } from "./scenarioRunner.js";

interface SessionSnapshot {
  id: string;
  rootDir: string;
  repoRoot: string;
  binaryPath: string;
  capabilities: Record<string, boolean>;
  manifests: ScenarioManifest[];
}

export class ShowcaseSessionManager {
  private session: SessionSnapshot | null = null;

  async reset(): Promise<DemoStateResponse> {
    await this.close();

    const repoRoot = findRepoRoot();
    const binaryPath = resolveSydraBinary(repoRoot);
    const sessionId = randomUUID();
    const sessionRoot = path.join(os.tmpdir(), `sydra-showcase-${sessionId}`);
    await fsp.mkdir(sessionRoot, { recursive: true });

    const manifests = await loadScenarioManifests();
    const capabilities = await this.detectCapabilities(sessionRoot, binaryPath);
    this.session = {
      id: sessionId,
      rootDir: sessionRoot,
      repoRoot,
      binaryPath,
      capabilities,
      manifests,
    };
    return this.toState();
  }

  async getState(): Promise<DemoStateResponse> {
    if (!this.session) {
      return this.reset();
    }
    return this.toState();
  }

  async runScenario(scenarioId: string): Promise<ScenarioRunResult> {
    const state = await this.getState();
    const session = this.session!;
    const manifest = session.manifests.find((entry) => entry.id === scenarioId);
    if (!manifest) {
      throw new Error(`Unknown scenario ${scenarioId}`);
    }

    const availability = buildScenarioAvailability([manifest], session.capabilities)[0];
    if (!availability.available) {
      return {
        scenarioId,
        status: "blocked",
        startedAt: new Date().toISOString(),
        finishedAt: new Date().toISOString(),
        sessionId: state.sessionId,
        workspaceRoot: session.rootDir,
        steps: [],
      };
    }

    const scenarioRoot = path.join(session.rootDir, "runs", `${scenarioId}-${Date.now()}`);
    await fsp.mkdir(scenarioRoot, { recursive: true });
    const seedRoutine = seedRoutines[manifest.seedRoutine];
    const cleanupRoutine = cleanupRoutines[manifest.cleanupRoutine] ?? cleanupSandbox;
    if (!seedRoutine) {
      throw new Error(`Unknown seed routine ${manifest.seedRoutine}`);
    }

    const sandbox = await seedRoutine(scenarioRoot, session.binaryPath);
    try {
      return await runScenarioManifest(manifest, sandbox, session.binaryPath, session.id);
    } finally {
      await cleanupRoutine(sandbox, true);
    }
  }

  async close(): Promise<void> {
    if (!this.session) {
      return;
    }
    await fsp.rm(this.session.rootDir, { recursive: true, force: true });
    this.session = null;
  }

  private async detectCapabilities(sessionRoot: string, binaryPath: string): Promise<Record<string, boolean>> {
    const binaryPresent = fs.existsSync(binaryPath);
    const capabilities: Record<string, boolean> = {
      "binary.present": binaryPresent,
      "cas.json": false,
      "cas.history": false,
      "sydraql.http": binaryPresent,
      "compiler.telemetry": binaryPresent,
      "cas.maintenance": binaryPresent,
      "cas.bundle": binaryPresent,
      "compiler.modes": binaryPresent,
      "multi_writer_head_writes": false,
    };

    if (!binaryPresent) {
      return capabilities;
    }

    const probeWorkspace = await createWorkspace(path.join(sessionRoot, "capability-probe"), "probe");
    try {
      const result = await runBinary(probeWorkspace, binaryPath, ["cas", "--json", "refs"]);
      const parsed = JSON.parse(result.stdout) as { schema_version?: number; command?: string };
      capabilities["cas.json"] = parsed.schema_version === 1 && parsed.command === "refs";
    } catch {
      capabilities["cas.json"] = false;
    }

    if (capabilities["cas.json"]) {
      const historyWorkspace = await createWorkspace(path.join(sessionRoot, "capability-probe"), "history");
      try {
        await seedWorkspaceFromFixtures(
          historyWorkspace,
          binaryPath,
          [path.join(fixturesDir, "edge-incident", "edge-east-baseline.ndjson")],
        );
        await runBinary(historyWorkspace, binaryPath, ["cas", "--json", "log"]);
        capabilities["cas.history"] = true;
      } catch {
        capabilities["cas.history"] = false;
      }

      const maintenanceWorkspace = await createWorkspace(path.join(sessionRoot, "capability-probe"), "maintenance");
      try {
        await seedWorkspaceFromFixtures(
          maintenanceWorkspace,
          binaryPath,
          [path.join(fixturesDir, "edge-incident", "edge-east-baseline.ndjson")],
        );
        await runBinary(maintenanceWorkspace, binaryPath, ["cas", "--json", "pack"]);
        await runBinary(maintenanceWorkspace, binaryPath, ["cas", "--json", "fsck", "--connectivity-only"]);
        await runBinary(maintenanceWorkspace, binaryPath, ["cas", "--json", "gc"]);
        await runBinary(maintenanceWorkspace, binaryPath, ["cas", "--json", "vacuum", "--repair"]);
        capabilities["cas.maintenance"] = true;
      } catch {
        capabilities["cas.maintenance"] = false;
      }

      const bundleWorkspace = await createWorkspace(path.join(sessionRoot, "capability-probe"), "bundle");
      try {
        await seedWorkspaceFromFixtures(
          bundleWorkspace,
          binaryPath,
          [path.join(fixturesDir, "edge-incident", "edge-east-baseline.ndjson")],
        );
        const bundleDir = path.join(bundleWorkspace.dir, "bundle-output");
        await runBinary(bundleWorkspace, binaryPath, ["cas", "--json", "bundle", "create", bundleDir]);
        await runBinary(bundleWorkspace, binaryPath, ["cas", "--json", "bundle", "verify", bundleDir]);
        capabilities["cas.bundle"] = true;
      } catch {
        capabilities["cas.bundle"] = false;
      }

      const compilerWorkspace = await createWorkspace(path.join(sessionRoot, "capability-probe"), "compiler", "compiled");
      const shadowWorkspace = await createWorkspace(path.join(sessionRoot, "capability-probe"), "shadow", "shadow");
      try {
        await seedWorkspaceFromFixtures(
          compilerWorkspace,
          binaryPath,
          [path.join(fixturesDir, "edge-incident", "edge-east-baseline.ndjson")],
        );
        await seedWorkspaceFromFixtures(
          shadowWorkspace,
          binaryPath,
          [path.join(fixturesDir, "edge-incident", "edge-east-baseline.ndjson")],
        );

        await startWorkspaceServer(compilerWorkspace, binaryPath);
        const compiledResult = (await postSydraqlQuery(
          compilerWorkspace,
          "select tag.host as host, avg(value) as avg_value from edge.power_kw where tag.site = 'edge-east' group by tag.host",
        )) as { stats?: { execution_mode?: string; trace_id?: string } };
        capabilities["compiler.telemetry"] =
          compiledResult.stats?.execution_mode === "compiled" &&
          typeof compiledResult.stats?.trace_id === "string" &&
          compiledResult.stats.trace_id.length > 0;
      } catch {
        capabilities["compiler.telemetry"] = false;
      } finally {
        await stopWorkspaceServer(compilerWorkspace).catch(() => {});
      }

      try {
        await startWorkspaceServer(shadowWorkspace, binaryPath);
        const shadowResult = (await postSydraqlQuery(shadowWorkspace, "select abs(-1)")) as {
          stats?: { execution_mode?: string; legacy_fallback?: boolean; fallback_reason?: string };
        };
        capabilities["compiler.modes"] =
          shadowResult.stats?.execution_mode === "shadow" &&
          shadowResult.stats?.legacy_fallback === true &&
          typeof shadowResult.stats?.fallback_reason === "string";
      } catch {
        capabilities["compiler.modes"] = false;
      } finally {
        await stopWorkspaceServer(shadowWorkspace).catch(() => {});
      }
    }

    return capabilities;
  }

  private toState(): DemoStateResponse {
    if (!this.session) {
      throw new Error("Showcase session is not initialized");
    }

    return {
      sessionId: this.session.id,
      sessionRoot: this.session.rootDir,
      repoRoot: this.session.repoRoot,
      binaryPath: this.session.binaryPath,
      capabilities: this.session.capabilities,
      scenarios: buildScenarioSummaries(this.session.manifests, this.session.capabilities),
    };
  }
}
