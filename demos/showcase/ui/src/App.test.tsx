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

describe("ShowcaseDashboard", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    window.localStorage.clear();
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
        loading={false}
        running={false}
        onSelectScenario={vi.fn()}
        onThemeChange={vi.fn()}
        onToggleReleaseMode={onToggleReleaseMode}
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

    await waitFor(() => expect(screen.getAllByRole("button", { name: "Run scenario" }).length).toBeGreaterThan(0));
    await waitFor(() => expect(document.documentElement.dataset.theme).toBe("dark"));

    fireEvent.click(screen.getByRole("button", { name: "Light" }));

    expect(document.documentElement.dataset.theme).toBe("light");
    expect(document.documentElement.style.colorScheme).toBe("light");
    expect(window.localStorage.getItem("sydra-showcase-theme")).toBe("light");
  });

  it("reads a persisted theme on first render", async () => {
    vi.mocked(fetchState).mockResolvedValue(mockState);
    window.localStorage.setItem("sydra-showcase-theme", "light");

    render(<App />);

    await waitFor(() => expect(screen.getAllByRole("button", { name: "Run scenario" }).length).toBeGreaterThan(0));
    await waitFor(() => expect(document.documentElement.dataset.theme).toBe("light"));
  });
});
