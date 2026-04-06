import { startTransition, useDeferredValue, useEffect, useState } from "react";

import type { DemoStateResponse, ScenarioRunResult, ScenarioStepResult } from "../../shared/contracts.js";
import { fetchState, resetSession, runScenario } from "./api.js";

interface ShowcaseDashboardProps {
  state: DemoStateResponse | null;
  selectedScenarioId: string | null;
  releaseMode: boolean;
  runResult: ScenarioRunResult | null;
  loading: boolean;
  running: boolean;
  onSelectScenario: (scenarioId: string) => void;
  onToggleReleaseMode: (value: boolean) => void;
  onResetSession: () => void;
  onRunScenario: () => void;
}

function formatValue(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }
  return JSON.stringify(value, null, 2);
}

function ScenarioStepCard({ step }: { step: ScenarioStepResult }) {
  const tone = step.status;
  return (
    <section className={`step-card step-card--${tone}`}>
      <header className="step-card__header">
        <div>
          <p className="eyebrow">{step.kind.replaceAll("_", " ")}</p>
          <h3>{step.title}</h3>
        </div>
        <span className={`status-pill status-pill--${tone}`}>{tone}</span>
      </header>
      <p className="step-card__summary">{step.summary}</p>
      {step.command ? <pre className="step-card__command">{step.command}</pre> : null}
      {step.assertions.length > 0 ? (
        <ul className="assertion-list">
          {step.assertions.map((assertion) => (
            <li key={`${assertion.path}-${assertion.operator}`} className={assertion.passed ? "assertion-pass" : "assertion-fail"}>
              <strong>{assertion.operator}</strong> {assertion.path || "(root)"} {assertion.passed ? "passed" : "failed"}
            </li>
          ))}
        </ul>
      ) : null}
      {step.output ? (
        <div className="evidence-grid">
          <article className="evidence-panel">
            <h4>Raw output</h4>
            <pre>{formatValue(step.output)}</pre>
          </article>
        </div>
      ) : null}
      {step.textOutput ? (
        <article className="evidence-panel">
          <h4>Command output</h4>
          <pre>{step.textOutput}</pre>
        </article>
      ) : null}
    </section>
  );
}

export function ShowcaseDashboard({
  state,
  selectedScenarioId,
  releaseMode,
  runResult,
  loading,
  running,
  onSelectScenario,
  onToggleReleaseMode,
  onResetSession,
  onRunScenario,
}: ShowcaseDashboardProps) {
  const deferredReleaseMode = useDeferredValue(releaseMode);
  const visibleScenarios = deferredReleaseMode
    ? (state?.scenarios ?? []).filter((entry) => entry.manifest.maturity !== "experimental")
    : (state?.scenarios ?? []);

  const selectedScenario =
    visibleScenarios.find((entry) => entry.manifest.id === selectedScenarioId) ?? visibleScenarios[0] ?? null;

  const plannedSteps = selectedScenario?.manifest.steps ?? [];

  return (
    <div className="showcase-shell">
      <header className="showcase-header">
        <div>
          <p className="eyebrow">SydraDB living showcase</p>
          <h1>Operational evidence for CAS, sydraQL, compiler work, and the core engine</h1>
        </div>
        <div className="showcase-header__actions">
          <label className="toggle">
            <input
              type="checkbox"
              checked={releaseMode}
              onChange={(event) => onToggleReleaseMode(event.target.checked)}
            />
            <span>Release mode</span>
          </label>
          <button className="secondary-button" onClick={onResetSession} disabled={loading || running}>
            Reset session
          </button>
          <button className="primary-button" onClick={onRunScenario} disabled={!selectedScenario || running || loading || !selectedScenario.availability.available}>
            {running ? "Running…" : "Run scenario"}
          </button>
        </div>
      </header>

      <div className="meta-strip">
        <span>Session: {state?.sessionId ?? "initializing"}</span>
        <span>Binary: {state?.binaryPath ?? "not found"}</span>
        <span>Capabilities: {Object.entries(state?.capabilities ?? {}).filter(([, enabled]) => enabled).length}</span>
      </div>

      <main className="showcase-grid">
        <aside className="scenario-pane">
          <div className="pane-heading">
            <p className="eyebrow">Scenario registry</p>
            <h2>Subsystem packs</h2>
          </div>
          <div className="scenario-list">
            {visibleScenarios.map((entry) => {
              const selected = entry.manifest.id === selectedScenario?.manifest.id;
              return (
                <button
                  key={entry.manifest.id}
                  className={`scenario-list__item ${selected ? "scenario-list__item--selected" : ""}`}
                  onClick={() => onSelectScenario(entry.manifest.id)}
                >
                  <div className="scenario-list__row">
                    <h3>{entry.manifest.title}</h3>
                    <span className={`maturity-pill maturity-pill--${entry.manifest.maturity}`}>
                      {entry.manifest.maturity}
                    </span>
                  </div>
                  <p>{entry.manifest.summary}</p>
                  <div className="scenario-tags">
                    {entry.manifest.subsystems.map((tag) => (
                      <span key={tag}>{tag}</span>
                    ))}
                  </div>
                  {!entry.availability.available ? (
                    <p className="scenario-list__missing">
                      Missing: {entry.availability.missingCapabilities.join(", ")}
                    </p>
                  ) : null}
                </button>
              );
            })}
          </div>
        </aside>

        <section className="evidence-pane">
          <div className="pane-heading">
            <p className="eyebrow">Execution evidence</p>
            <h2>{selectedScenario?.manifest.title ?? "No scenario selected"}</h2>
          </div>
          {runResult?.scenarioId === selectedScenario?.manifest.id ? (
            <>
              {runResult.summaryEvidence ? (
                <article className="summary-evidence">
                  <h3>Stable summary evidence</h3>
                  <pre>{formatValue(runResult.summaryEvidence)}</pre>
                </article>
              ) : null}
              <div className="step-stack">
                {runResult.steps.map((step) => (
                  <ScenarioStepCard key={step.id} step={step} />
                ))}
              </div>
            </>
          ) : (
            <div className="planned-steps">
              {plannedSteps.map((step, index) => (
                <article key={step.id} className="planned-step">
                  <span className="planned-step__index">{String(index + 1).padStart(2, "0")}</span>
                  <div>
                    <h3>{step.title}</h3>
                    <p>{step.summary}</p>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>

        <aside className="context-pane">
          <div className="pane-heading">
            <p className="eyebrow">Decision context</p>
            <h2>Why not standard SQLite here?</h2>
          </div>
          {selectedScenario ? (
            <>
              <p className="context-pane__summary">{selectedScenario.manifest.summary}</p>
              <ul className="reason-list">
                {selectedScenario.manifest.whySQLiteFallsShort.map((reason) => (
                  <li key={reason}>{reason}</li>
                ))}
              </ul>
              <section className="context-pane__details">
                <h3>Minimum outputs</h3>
                <ul>
                  {selectedScenario.manifest.minimumOutputs.map((output) => (
                    <li key={output}>{output}</li>
                  ))}
                </ul>
              </section>
              <section className="context-pane__details">
                <h3>Scenario evidence panels</h3>
                <ul>
                  {plannedSteps.flatMap((step) =>
                    step.evidencePanels.map((panel) => (
                      <li key={`${step.id}-${panel.id}`}>
                        {step.title}: {panel.title}
                      </li>
                    )),
                  )}
                </ul>
              </section>
            </>
          ) : (
            <p>Select a scenario to inspect the tradeoffs it highlights.</p>
          )}
        </aside>
      </main>
    </div>
  );
}

export default function App() {
  const [state, setState] = useState<DemoStateResponse | null>(null);
  const [selectedScenarioId, setSelectedScenarioId] = useState<string | null>(null);
  const [runResult, setRunResult] = useState<ScenarioRunResult | null>(null);
  const [releaseMode, setReleaseMode] = useState(false);
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);

  useEffect(() => {
    let cancelled = false;
    fetchState()
      .then((nextState) => {
        if (cancelled) return;
        setState(nextState);
        startTransition(() => {
          setSelectedScenarioId((current) => current ?? nextState.scenarios[0]?.manifest.id ?? null);
        });
      })
      .finally(() => {
        if (!cancelled) {
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function handleResetSession() {
    setLoading(true);
    const nextState = await resetSession();
    setState(nextState);
    setRunResult(null);
    startTransition(() => {
      setSelectedScenarioId(nextState.scenarios[0]?.manifest.id ?? null);
    });
    setLoading(false);
  }

  async function handleRunScenario() {
    if (!selectedScenarioId) {
      return;
    }
    setRunning(true);
    const nextResult = await runScenario(selectedScenarioId);
    setRunResult(nextResult);
    setRunning(false);
  }

  return (
    <ShowcaseDashboard
      state={state}
      selectedScenarioId={selectedScenarioId}
      releaseMode={releaseMode}
      runResult={runResult}
      loading={loading}
      running={running}
      onSelectScenario={(scenarioId) => {
        startTransition(() => {
          setSelectedScenarioId(scenarioId);
          setRunResult(null);
        });
      }}
      onToggleReleaseMode={setReleaseMode}
      onResetSession={handleResetSession}
      onRunScenario={handleRunScenario}
    />
  );
}
