import fs from "node:fs";
import path from "node:path";

import { DemoSessionManager } from "../../shared/runtime/sessionManager.js";
import { createWorkspace, postRangeQuery, postSydraqlQuery, runBinary, seedWorkspaceFromFixtures, startWorkspaceServer, stopWorkspaceServer } from "./runtime.js";
import { cleanupRoutines, seedRoutines } from "./seeders.js";
import { fixturesDir, resolveSydraBinary, showcaseRoot } from "./paths.js";
import { loadScenarioManifests } from "./scenarioRegistry.js";
import { buildSummaryEvidence } from "./summaryEvidence.js";

async function detectCapabilities(sessionRoot: string, binaryPath: string): Promise<Record<string, boolean>> {
  const binaryPresent = fs.existsSync(binaryPath);
  const capabilities: Record<string, boolean> = {
    "binary.present": binaryPresent,
    "cas.json": false,
    "cas.history": false,
    "sydraql.http": false,
    "compiler.telemetry": false,
    "cas.maintenance": false,
    "cas.bundle": false,
    "compiler.modes": false,
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

  const httpWorkspace = await createWorkspace(path.join(sessionRoot, "capability-probe"), "http");
  try {
    await seedWorkspaceFromFixtures(
      httpWorkspace,
      binaryPath,
      [path.join(fixturesDir, "edge-incident", "edge-east-baseline.ndjson")],
    );
    await startWorkspaceServer(httpWorkspace, binaryPath);
    const rangeResult = await postRangeQuery(httpWorkspace, {
      series: "edge.power_kw",
      tags: {
        site: "edge-east",
        host: "edge-east-gw-1",
        firmware: "1.2.0",
        sensor: "power",
      },
      start: 1700000000,
      end: 1700000400,
    });
    capabilities["sydraql.http"] = Array.isArray(rangeResult) && rangeResult.length >= 1;
  } catch {
    capabilities["sydraql.http"] = false;
  } finally {
    await stopWorkspaceServer(httpWorkspace).catch(() => {});
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
      await seedWorkspaceFromFixtures(
        shadowWorkspace,
        binaryPath,
        [path.join(fixturesDir, "edge-incident", "edge-east-baseline.ndjson")],
      );
      await startWorkspaceServer(shadowWorkspace, binaryPath);
      const shadowResult = (await postSydraqlQuery(
        shadowWorkspace,
        "select time_bucket(60, time) as bucket, avg(value) as avg_value from edge.power_kw where time >= 0 group by time_bucket(60, time) fill(linear) order by bucket desc",
      )) as {
        stats?: { execution_mode?: string; legacy_fallback?: boolean; fallback_reason?: string };
      };
      capabilities["compiler.modes"] =
        shadowResult.stats?.execution_mode === "shadow" &&
        shadowResult.stats?.legacy_fallback === true &&
        shadowResult.stats?.fallback_reason === "unsupported_fill";
    } catch {
      capabilities["compiler.modes"] = false;
    } finally {
      await stopWorkspaceServer(shadowWorkspace).catch(() => {});
    }
  }

  return capabilities;
}

export class ShowcaseSessionManager extends DemoSessionManager {
  constructor() {
    super({
      appId: "showcase",
      appPaths: {
        appRoot: showcaseRoot,
        scenariosDir: path.join(showcaseRoot, "scenarios"),
        fixturesDir: path.join(showcaseRoot, "fixtures"),
        uiRoot: path.join(showcaseRoot, "ui"),
      },
      loadManifests: loadScenarioManifests,
      detectCapabilities,
      seedRoutines,
      cleanupRoutines,
      summaryEvidenceBuilder: buildSummaryEvidence,
    });
  }
}
