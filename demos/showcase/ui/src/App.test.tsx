import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { DemoStateResponse, ScenarioRunResult } from "../../shared/contracts.js";
import App, { ShowcaseDashboard } from "./App.js";
import { fetchState } from "./api.js";

vi.mock("./api.js", () => ({
  fetchState: vi.fn(),
  resetSession: vi.fn(),
  runScenario: vi.fn(),
}));

const mockState: DemoStateResponse = {
  sessionId: "session-1",
  sessionRoot: "/tmp/session-1",
  repoRoot: "/repo",
  binaryPath: "/repo/zig-out/bin/sydradb",
  capabilities: {
    "binary.present": true,
    "cas.json": true,
    "sydraql.http": true,
    "compiler.telemetry": true,
    "cas.maintenance": true,
    "cas.bundle": true,
    "compiler.modes": true,
    "multi_writer_head_writes": false,
  },
  scenarios: [
    {
      availability: { id: "candidate-scenario", available: true, missingCapabilities: [] },
      manifest: {
        schemaVersion: 1,
        id: "candidate-scenario",
        title: "Candidate scenario",
        summary: "A stable scenario",
        maturity: "candidate",
        subsystems: ["cas"],
        requiredCapabilities: ["cas.json"],
        minimumOutputs: ["foo"],
        seedRoutine: "seed",
        cleanupRoutine: "cleanup",
        whySQLiteFallsShort: ["Needs refs."],
        steps: [],
      },
    },
    {
      availability: { id: "experimental-scenario", available: false, missingCapabilities: ["multi_writer_head_writes"] },
      manifest: {
        schemaVersion: 1,
        id: "experimental-scenario",
        title: "Experimental scenario",
        summary: "Reserved",
        maturity: "experimental",
        subsystems: ["cas"],
        requiredCapabilities: ["multi_writer_head_writes"],
        minimumOutputs: ["bar"],
        seedRoutine: "seed",
        cleanupRoutine: "cleanup",
        whySQLiteFallsShort: ["Needs multi-writer heads."],
        steps: [],
      },
    },
  ],
};

const guidedState: DemoStateResponse = {
  ...mockState,
  scenarios: [
    {
      availability: { id: "cas-history", available: true, missingCapabilities: [] },
      manifest: {
        schemaVersion: 1,
        id: "cas-history",
        title: "CAS History and Recovery",
        summary: "Inspect Git-like history, compare snapshots, and roll back an edge-site incident using SydraDB's immutable metadata model.",
        maturity: "alpha",
        subsystems: ["cas", "git-model", "engine"],
        requiredCapabilities: ["cas.json"],
        minimumOutputs: ["refs.entries"],
        seedRoutine: "seed",
        cleanupRoutine: "cleanup",
        whySQLiteFallsShort: ["History is first-class."],
        steps: [
          {
            id: "log",
            title: "Read commit history",
            summary: "Show the CAS log for heads/main so the incident and rollback context are visible as commit history.",
            kind: "cas_command",
            workspace: "edge-east",
            args: ["log"],
            evidencePanels: [
              { id: "log-entries", title: "Commit log", kind: "json", sourcePath: "entries" },
            ],
          },
        ],
      },
    },
  ],
};

const guidedRunResult: ScenarioRunResult = {
  scenarioId: "cas-history",
  status: "passed",
  startedAt: "2026-04-05T23:00:00.000Z",
  finishedAt: "2026-04-05T23:00:02.000Z",
  sessionId: "session-1",
  workspaceRoot: "/tmp/session-1",
  summaryEvidence: { rollback: "verified" },
  steps: [
    {
      id: "log",
      title: "Read commit history",
      summary: "Show the CAS log for heads/main so the incident and rollback context are visible as commit history.",
      kind: "cas_command",
      status: "failed",
      output: { entries: [{ commit_id: "abc" }, { commit_id: "def" }] },
      assertions: [],
    },
  ],
};

function clearCookie(name: string) {
  document.cookie = `${name}=; Path=/; Max-Age=0; SameSite=Lax`;
}

describe("ShowcaseDashboard", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    window.localStorage.clear();
    window.history.pushState({}, "", "/core");
    clearCookie("sydra_showcase_launch_cards");
    delete document.documentElement.dataset.theme;
    document.documentElement.style.colorScheme = "";
  });

  afterEach(() => {
    cleanup();
  });

  it("filters experimental scenarios in release mode", () => {
    const onToggleReleaseMode = vi.fn();
    render(
      <ShowcaseDashboard
        state={mockState}
        selectedScenarioId="candidate-scenario"
        releaseMode={false}
        runResult={null}
        theme="dark"
        error={null}
        launchCardsVisible={false}
        dismissedLaunchCardIds={[]}
        loading={false}
        running={false}
        onSelectScenario={vi.fn()}
        onThemeChange={vi.fn()}
        onToggleReleaseMode={onToggleReleaseMode}
        onToggleLaunchCards={vi.fn()}
        onDismissLaunchCard={vi.fn()}
        onDismissAllLaunchCards={vi.fn()}
        onResetSession={vi.fn()}
        onRunScenario={vi.fn()}
      />,
    );

    expect(screen.getByText("Experimental scenario")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("checkbox"));
    expect(onToggleReleaseMode).toHaveBeenCalledWith(true);
  });

  it("renders the category launcher at the default route", async () => {
    window.history.pushState({}, "", "/");
    vi.mocked(fetchState).mockResolvedValue(mockState);

    render(<App />);

    expect(screen.getByText("Choose the story you want to walk through first")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open core showcase" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Open trading showcase" })).toHaveAttribute("href", "http://localhost:4277/");
  });

  it("defaults to dark mode and persists theme changes", async () => {
    vi.mocked(fetchState).mockResolvedValue(mockState);

    render(<App />);

    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).toBeInTheDocument());
    await waitFor(() => expect(document.documentElement.dataset.theme).toBe("dark"));

    fireEvent.click(screen.getByRole("button", { name: "Dark" }));

    expect(document.documentElement.dataset.theme).toBe("light");
    expect(document.documentElement.style.colorScheme).toBe("light");
    expect(window.localStorage.getItem("sydra-showcase-theme")).toBe("light");
  });

  it("reads a persisted theme on first render", async () => {
    vi.mocked(fetchState).mockResolvedValue(mockState);
    window.localStorage.setItem("sydra-showcase-theme", "light");

    render(<App />);

    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).toBeInTheDocument());
    await waitFor(() => expect(document.documentElement.dataset.theme).toBe("light"));
  });

  it("shows launch notes on first load and persists dismissal in cookies", async () => {
    vi.mocked(fetchState).mockResolvedValue(mockState);

    render(<App />);

    await waitFor(() => expect(screen.getByText("Local telemetry at the edge")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "Dismiss launch notes" }));

    await waitFor(() => expect(screen.queryByText("Local telemetry at the edge")).not.toBeInTheDocument());
    expect(document.cookie).toContain("sydra_showcase_launch_cards=hidden");
    expect(screen.getByRole("button", { name: "Show launch notes" })).toBeInTheDocument();
  });

  it("keeps launch notes hidden after dismissal but allows manual reopen", async () => {
    vi.mocked(fetchState).mockResolvedValue(mockState);
    document.cookie = "sydra_showcase_launch_cards=hidden; Path=/; SameSite=Lax";

    render(<App />);

    await waitFor(() => expect(screen.getByRole("button", { name: "Show launch notes" })).toBeInTheDocument());
    expect(screen.queryByText("Local telemetry at the edge")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Show launch notes" }));

    await waitFor(() => expect(screen.getByText("Local telemetry at the edge")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "Hide launch notes" })).toBeInTheDocument();
  });

  it("adds a guided reading layer when a scenario has run", () => {
    render(
      <ShowcaseDashboard
        state={guidedState}
        selectedScenarioId="cas-history"
        releaseMode={false}
        runResult={guidedRunResult}
        theme="dark"
        error={null}
        launchCardsVisible={false}
        dismissedLaunchCardIds={[]}
        loading={false}
        running={false}
        onSelectScenario={vi.fn()}
        onThemeChange={vi.fn()}
        onToggleReleaseMode={vi.fn()}
        onToggleLaunchCards={vi.fn()}
        onDismissLaunchCard={vi.fn()}
        onDismissAllLaunchCards={vi.fn()}
        onResetSession={vi.fn()}
        onRunScenario={vi.fn()}
      />,
    );

    expect(screen.getByText("How to read this run")).toBeInTheDocument();
    expect(screen.getByText("If you are a manager")).toBeInTheDocument();
    expect(screen.getByText("What this step means")).toBeInTheDocument();
    expect(screen.getByText(/one site in the fleet takes on a bad state/i)).toBeInTheDocument();
    expect(screen.getByText("Commit log")).toBeInTheDocument();
  });

  it("explains what SydraDB stores and how it is used in the model tab", () => {
    render(
      <ShowcaseDashboard
        state={guidedState}
        selectedScenarioId="cas-history"
        releaseMode={false}
        runResult={null}
        theme="dark"
        error={null}
        launchCardsVisible={false}
        dismissedLaunchCardIds={[]}
        loading={false}
        running={false}
        onSelectScenario={vi.fn()}
        onThemeChange={vi.fn()}
        onToggleReleaseMode={vi.fn()}
        onToggleLaunchCards={vi.fn()}
        onDismissLaunchCard={vi.fn()}
        onDismissAllLaunchCards={vi.fn()}
        onResetSession={vi.fn()}
        onRunScenario={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "How it works" }));

    expect(screen.getByText("What SydraDB stores today")).toBeInTheDocument();
    expect(screen.getByText(/tagged numeric time-series points/i)).toBeInTheDocument();
    expect(screen.getByText("How applications fill it")).toBeInTheDocument();
    expect(screen.getByText(/POST \/api\/v1\/ingest/i)).toBeInTheDocument();
  });
});
