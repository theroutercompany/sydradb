import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import type { DemoStateResponse } from "../../shared/contracts.js";
import { ShowcaseDashboard } from "./App.js";

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
  it("filters experimental scenarios in release mode", () => {
    const onToggleReleaseMode = vi.fn();
    render(
      <ShowcaseDashboard
        state={mockState}
        selectedScenarioId="candidate-scenario"
        releaseMode={false}
        runResult={null}
        loading={false}
        running={false}
        onSelectScenario={vi.fn()}
        onToggleReleaseMode={onToggleReleaseMode}
        onResetSession={vi.fn()}
        onRunScenario={vi.fn()}
      />,
    );

    expect(screen.getByText("Experimental scenario")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("checkbox"));
    expect(onToggleReleaseMode).toHaveBeenCalledWith(true);
  });
});
