import fs from "node:fs";
import path from "node:path";

import { DemoSessionManager } from "../../shared/runtime/sessionManager.js";
import { createWorkspace, requestWorkspace, runBinary, startWorkspaceServer, stopWorkspaceServer } from "./runtime.js";
import { cleanupRoutines, seedRoutines } from "./seeders.js";
import { buildTradingSummaryEvidence } from "./summaryEvidence.js";
import { fixturesDir, tradingShowcaseRoot } from "./paths.js";
import { loadScenarioManifests } from "./scenarioRegistry.js";

async function registerSchemas(baseUrlWorkspace: Awaited<ReturnType<typeof createWorkspace>>) {
  await requestWorkspace(baseUrlWorkspace, {
    method: "POST",
    path: "/api/v1/market/schema/register",
    contentType: "application/json",
    body: {
      metric: "market.trade",
      ordered_columns: ["price", "size"],
      required_labels: ["symbol", "venue"],
      storage_mapping: "fanout_v1",
    },
  });
  await requestWorkspace(baseUrlWorkspace, {
    method: "POST",
    path: "/api/v1/market/schema/register",
    contentType: "application/json",
    body: {
      metric: "market.quote",
      ordered_columns: ["bid", "ask", "bid_size", "ask_size"],
      required_labels: ["symbol", "venue"],
      storage_mapping: "fanout_v1",
    },
  });
}

async function detectCapabilities(sessionRoot: string, binaryPath: string): Promise<Record<string, boolean>> {
  const binaryPresent = fs.existsSync(binaryPath);
  const capabilities: Record<string, boolean> = {
    "binary.present": binaryPresent,
    "market.http": false,
    "trading.definitions": false,
    "trading.analysis": false,
    "trading.cas.revisions": false,
  };

  if (!binaryPresent) {
    return capabilities;
  }

  const baselineNdjson = await fs.promises.readFile(path.join(fixturesDir, "market-data", "baseline.ndjson"), "utf8");
  const correctedNdjson = await fs.promises.readFile(path.join(fixturesDir, "market-data", "corrected.ndjson"), "utf8");
  const revisionBaselineNdjson = await fs.promises.readFile(path.join(fixturesDir, "market-data", "revision-baseline.ndjson"), "utf8");

  const legacyWorkspace = await createWorkspace(path.join(sessionRoot, "capability-probe"), "legacy-probe", "compiled", {
    casMode: "off",
    metadataReadMode: "legacy",
  });

  try {
    await startWorkspaceServer(legacyWorkspace, binaryPath);
    await registerSchemas(legacyWorkspace);
    await requestWorkspace(legacyWorkspace, {
      method: "POST",
      path: "/api/v1/market/ingest",
      contentType: "application/x-ndjson",
      body: revisionBaselineNdjson,
    });
    await new Promise((resolve) => setTimeout(resolve, 1_200));
    const tradeQuery = await requestWorkspace(legacyWorkspace, {
      method: "POST",
      path: "/api/v1/market/query",
      contentType: "application/json",
      body: {
        metric: "market.trade",
        labels: { symbol: "AAPL", venue: "XNAS" },
        start_ts_ns: 1712741400000000000,
        end_ts_ns: 1712741500000000000,
      },
    }) as { rows?: unknown[] };
    capabilities["market.http"] = Array.isArray(tradeQuery.rows) && tradeQuery.rows.length >= 2;

    await requestWorkspace(legacyWorkspace, {
      method: "POST",
      path: "/api/v1/bar-policies/register",
      contentType: "application/json",
      body: {
        id: "regular-hours-1m",
        source_metric: "market.trade",
        interval_ns: 60_000_000_000,
        session_rule: "regular_hours",
        no_trade_rule: "carry_forward_none",
        halt_rule: "skip_halts",
        correction_policy: "append_only",
      },
    });
    await requestWorkspace(legacyWorkspace, {
      method: "POST",
      path: "/api/v1/rollups/register",
      contentType: "application/json",
      body: {
        id: "bars-1m",
        source_metric: "market.trade",
        target_metric: "market.bar",
        policy_id: "regular-hours-1m",
        transform_kind: "trade_to_bar",
      },
    });
    await requestWorkspace(legacyWorkspace, {
      method: "POST",
      path: "/api/v1/signals/register",
      contentType: "application/json",
      body: {
        id: "ema-fast",
        input_metric: "market.bar",
        policy_id: "regular-hours-1m",
        expression_kind: "ema",
        params: { period: 3 },
        emit_rule: "on_close",
      },
    });
    const rollups = await requestWorkspace(legacyWorkspace, {
      method: "GET",
      path: "/api/v1/rollups",
    }) as Array<{ runtime?: { emissions_total?: number } }>;
    const signals = await requestWorkspace(legacyWorkspace, {
      method: "GET",
      path: "/api/v1/signals",
    }) as Array<{ runtime?: { status?: string } }>;
    capabilities["trading.definitions"] =
      Array.isArray(rollups) &&
      rollups.length >= 1 &&
      Array.isArray(signals) &&
      signals[0]?.runtime?.status === "active";

    const slippage = await requestWorkspace(legacyWorkspace, {
      method: "POST",
      path: "/api/v1/analysis/slippage",
      contentType: "application/json",
      body: {
        venue: "XNAS",
        group_by: "symbol",
        start_ts_ns: 1712741400000000000,
        end_ts_ns: 1712741500000000000,
      },
    }) as { groups?: unknown[] };
    const quoteQuality = await requestWorkspace(legacyWorkspace, {
      method: "POST",
      path: "/api/v1/analysis/quote-quality",
      contentType: "application/json",
      body: {
        symbol: "AAPL",
        group_by: "venue",
        start_ts_ns: 1712741400000000000,
        end_ts_ns: 1712741500000000000,
      },
    }) as { groups?: unknown[] };
    capabilities["trading.analysis"] =
      Array.isArray(slippage.groups) &&
      slippage.groups.length >= 1 &&
      Array.isArray(quoteQuality.groups) &&
      quoteQuality.groups.length >= 1;
  } catch {
    capabilities["market.http"] = false;
  } finally {
    await stopWorkspaceServer(legacyWorkspace).catch(() => {});
  }

  const casWorkspace = await createWorkspace(path.join(sessionRoot, "capability-probe"), "cas-probe", "compiled", {
    casMode: "dual_write",
    metadataReadMode: "primary",
  });

  try {
    await startWorkspaceServer(casWorkspace, binaryPath);
    await registerSchemas(casWorkspace);
    await requestWorkspace(casWorkspace, {
      method: "POST",
      path: "/api/v1/market/ingest",
      contentType: "application/x-ndjson",
      body: baselineNdjson,
    });
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    await runBinary(casWorkspace, binaryPath, ["cas", "branch", "before-correction"]);
    await requestWorkspace(casWorkspace, {
      method: "POST",
      path: "/api/v1/market/ingest",
      contentType: "application/x-ndjson",
      body: correctedNdjson,
    });
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    const before = await requestWorkspace(casWorkspace, {
      method: "POST",
      path: "/api/v1/analysis/markout",
      contentType: "application/json",
      body: {
        venue: "XNAS",
        group_by: "symbol",
        start_ts_ns: 1712741400000000000,
        end_ts_ns: 1712741500000000000,
        horizons_ns: [30_000_000_000],
        revision: "heads/before-correction",
      },
    }) as { groups?: Array<{ key?: { symbol?: string }; horizons?: Array<{ value?: number }> }> };
    const after = await requestWorkspace(casWorkspace, {
      method: "POST",
      path: "/api/v1/analysis/markout",
      contentType: "application/json",
      body: {
        venue: "XNAS",
        group_by: "symbol",
        start_ts_ns: 1712741400000000000,
        end_ts_ns: 1712741500000000000,
        horizons_ns: [30_000_000_000],
        revision: "heads/main",
      },
    }) as { groups?: Array<{ key?: { symbol?: string }; horizons?: Array<{ value?: number }> }> };
    const beforeAapl = before.groups?.find((group) => group.key?.symbol === "AAPL")?.horizons?.[0]?.value;
    const afterAapl = after.groups?.find((group) => group.key?.symbol === "AAPL")?.horizons?.[0]?.value;
    capabilities["trading.cas.revisions"] =
      Array.isArray(before.groups) &&
      before.groups.length >= 1 &&
      Array.isArray(after.groups) &&
      after.groups.length >= 1 &&
      typeof beforeAapl === "number" &&
      typeof afterAapl === "number" &&
      beforeAapl !== afterAapl;
  } catch {
    capabilities["trading.cas.revisions"] = false;
  } finally {
    await stopWorkspaceServer(casWorkspace).catch(() => {});
  }

  return capabilities;
}

export class TradingShowcaseSessionManager extends DemoSessionManager {
  constructor() {
    super({
      appId: "trading-showcase",
      appPaths: {
        appRoot: tradingShowcaseRoot,
        scenariosDir: path.join(tradingShowcaseRoot, "scenarios"),
        fixturesDir: path.join(tradingShowcaseRoot, "fixtures"),
        uiRoot: path.join(tradingShowcaseRoot, "ui"),
      },
      loadManifests: loadScenarioManifests,
      detectCapabilities,
      seedRoutines,
      cleanupRoutines,
      summaryEvidenceBuilder: buildTradingSummaryEvidence,
    });
  }
}
