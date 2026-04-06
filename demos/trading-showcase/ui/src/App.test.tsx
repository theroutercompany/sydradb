import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { DemoStateResponse, ScenarioRunResult } from "../../shared/contracts.js";
import App from "./App.js";

vi.mock("./api.js", () => ({
  fetchState: vi.fn(),
  resetSession: vi.fn(),
  runScenario: vi.fn(),
}));

import { fetchState, runScenario } from "./api.js";

const mockState: DemoStateResponse = {
  sessionId: "session-1",
  sessionRoot: "/tmp/trading-session",
  repoRoot: "/repo",
  binaryPath: "/repo/zig-out/bin/sydradb",
  capabilities: {
    "binary.present": true,
    "market.http": true,
    "trading.definitions": true,
    "trading.analysis": true,
    "trading.cas.revisions": true,
  },
  scenarios: [
    {
      availability: { id: "feed-and-schema", available: true, missingCapabilities: [] },
      manifest: {
        schemaVersion: 1,
        id: "feed-and-schema",
        title: "Feed and schema",
        summary: "Write market rows into SydraDB and query them back.",
        maturity: "candidate",
        subsystems: ["market", "trading"],
        requiredCapabilities: ["market.http"],
        minimumOutputs: ["rows"],
        seedRoutine: "seedTradingFeed",
        cleanupRoutine: "cleanupWorkspaceSandbox",
        whySQLiteFallsShort: ["Storage alone does not explain the feed shape."],
        steps: [
          {
            id: "query-aapl-trades",
            title: "Query AAPL trades",
            summary: "Read back a market row.",
            kind: "http_request",
            workspace: "trading-desk",
            method: "POST",
            path: "/api/v1/market/query",
            body: {},
            contentType: "application/json",
            evidencePanels: [{ id: "rows", title: "Rows", kind: "rows", sourcePath: "rows" }],
          },
        ],
      },
    },
    {
      availability: { id: "analysis-and-replay", available: false, missingCapabilities: ["trading.cas.revisions"] },
      manifest: {
        schemaVersion: 1,
        id: "analysis-and-replay",
        title: "Analysis and replay",
        summary: "Compare corrected data across revisions.",
        maturity: "alpha",
        subsystems: ["analysis", "cas"],
        requiredCapabilities: ["trading.cas.revisions"],
        minimumOutputs: ["groups"],
        seedRoutine: "seedTradingAnalysis",
        cleanupRoutine: "cleanupWorkspaceSandbox",
        whySQLiteFallsShort: ["Revision-aware analysis is not first-class."],
        steps: [],
      },
    },
  ],
};

const runResult: ScenarioRunResult = {
  scenarioId: "feed-and-schema",
  status: "passed",
  startedAt: "2026-04-06T00:00:00.000Z",
  finishedAt: "2026-04-06T00:00:03.000Z",
  sessionId: "session-1",
  workspaceRoot: "/tmp/trading-session",
  summaryEvidence: { ingestedRows: 16 },
  steps: [
    {
      id: "query-aapl-trades",
      title: "Query AAPL trades",
      summary: "Read back a market row.",
      kind: "http_request",
      status: "passed",
      output: {
        rows: [{ columns: { price: 185.1 } }],
      },
      assertions: [],
    },
  ],
};

describe("Trading showcase UI", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    window.localStorage.clear();
    vi.mocked(fetchState).mockResolvedValue(mockState);
  });

  afterEach(() => {
    cleanup();
  });

  it("renders the trading hero and scenario groups", async () => {
    render(<App />);

    await waitFor(() => expect(screen.getByText(/Market data in, runtime state out/i)).toBeInTheDocument());
    expect(screen.getAllByText("Feed and schema").length).toBeGreaterThan(0);
    expect(screen.getByText("Analysis and replay")).toBeInTheDocument();
  });

  it("runs the selected scenario and shows summary evidence", async () => {
    vi.mocked(runScenario).mockResolvedValue(runResult);

    render(<App />);
    await waitFor(() => expect(screen.getAllByRole("button", { name: "Run scenario" }).length).toBeGreaterThan(0));

    fireEvent.click(screen.getAllByRole("button", { name: "Run scenario" })[0]);

    await waitFor(() => expect(screen.getByText("Fast read")).toBeInTheDocument());
    expect(screen.getByText(/ingestedRows/i)).toBeInTheDocument();
  });
});
