import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { DemoStateResponse } from "../../shared/contracts.js";
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

function clearCookie(name: string) {
  document.cookie = `${name}=; Path=/; Max-Age=0; SameSite=Lax`;
}

describe("ShowcaseDashboard", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    window.localStorage.clear();
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

    await waitFor(() => expect(screen.getByText("Edge fleet story")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "Dismiss launch notes" }));

    await waitFor(() => expect(screen.queryByText("Edge fleet story")).not.toBeInTheDocument());
    expect(document.cookie).toContain("sydra_showcase_launch_cards=hidden");
    expect(screen.getByRole("button", { name: "Show launch notes" })).toBeInTheDocument();
  });

  it("keeps launch notes hidden after dismissal but allows manual reopen", async () => {
    vi.mocked(fetchState).mockResolvedValue(mockState);
    document.cookie = "sydra_showcase_launch_cards=hidden; Path=/; SameSite=Lax";

    render(<App />);

    await waitFor(() => expect(screen.getByRole("button", { name: "Show launch notes" })).toBeInTheDocument());
    expect(screen.queryByText("Edge fleet story")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Show launch notes" }));

    await waitFor(() => expect(screen.getByText("Edge fleet story")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "Hide launch notes" })).toBeInTheDocument();
  });
});
