import { startTransition, useDeferredValue, useEffect, useState } from "react";

import type { DemoStateResponse, ScenarioRunResult, ScenarioStepResult } from "../../shared/contracts.js";
import { fetchState, resetSession, runScenario } from "./api.js";

type ThemeMode = "dark" | "light";

const THEME_STORAGE_KEY = "sydra-showcase-theme";

interface ShowcaseDashboardProps {
  state: DemoStateResponse | null;
  selectedScenarioId: string | null;
  releaseMode: boolean;
  runResult: ScenarioRunResult | null;
  theme: ThemeMode;
  error: string | null;
  loading: boolean;
  running: boolean;
  onSelectScenario: (scenarioId: string) => void;
  onThemeChange: (theme: ThemeMode) => void;
  onToggleReleaseMode: (value: boolean) => void;
  onResetSession: () => void;
  onRunScenario: () => void;
}

function readInitialTheme(): ThemeMode {
  if (typeof window === "undefined") {
    return "dark";
  }
  try {
    const storedTheme = window.localStorage.getItem(THEME_STORAGE_KEY);
    return storedTheme === "light" || storedTheme === "dark" ? storedTheme : "dark";
  } catch {
    return "dark";
  }
}

function formatValue(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }
  return JSON.stringify(value, null, 2);
}

function formatTimestamp(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return date.toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
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
  theme,
  error,
  loading,
  running,
  onSelectScenario,
  onThemeChange,
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
  const enabledCapabilityCount = Object.entries(state?.capabilities ?? {}).filter(([, enabled]) => enabled).length;
  const selectedRunVisible =
    runResult && selectedScenario && runResult.scenarioId === selectedScenario.manifest.id ? runResult : null;

  return (
    <div className="showcase-shell">
      <div className="showcase-backdrop" aria-hidden="true" />
      <header className="showcase-header">
        <div className="showcase-header__intro">
          <p className="eyebrow">SydraDB living showcase</p>
          <h1>Operational evidence for CAS, sydraQL, compiler work, and the core engine</h1>
          <p className="showcase-header__lede">
            Dark-first scenario packs for validating fast-moving trunk work with real repos, live binaries, and
            operator-grade evidence.
          </p>
        </div>
        <div className="showcase-header__actions">
          <div className="theme-toggle" role="group" aria-label="Theme mode">
            <span className="theme-toggle__label">Theme</span>
            {(["dark", "light"] as const).map((option) => (
              <button
                key={option}
                type="button"
                className={`theme-toggle__button ${theme === option ? "theme-toggle__button--active" : ""}`}
                aria-pressed={theme === option}
                onClick={() => onThemeChange(option)}
              >
                {option === "dark" ? "Midnight" : "Light"}
              </button>
            ))}
          </div>
          <label className="toggle">
            <input
              type="checkbox"
              checked={releaseMode}
              onChange={(event) => onToggleReleaseMode(event.target.checked)}
            />
            <span>Release mode</span>
          </label>
          <button type="button" className="secondary-button" onClick={onResetSession} disabled={loading || running}>
            Reset session
          </button>
          <button
            type="button"
            className="primary-button"
            onClick={onRunScenario}
            disabled={!selectedScenario || running || loading || !selectedScenario.availability.available}
          >
            {running ? "Running…" : "Run scenario"}
          </button>
        </div>
      </header>

      <div className="meta-strip">
        <article className="meta-pill">
          <span className="meta-pill__label">Session</span>
          <strong>{state?.sessionId ?? "initializing"}</strong>
        </article>
        <article className="meta-pill">
          <span className="meta-pill__label">Binary</span>
          <strong>{state?.binaryPath ?? "not found"}</strong>
        </article>
        <article className="meta-pill">
          <span className="meta-pill__label">Capabilities online</span>
          <strong>{enabledCapabilityCount}</strong>
        </article>
        <article className="meta-pill">
          <span className="meta-pill__label">Scenario packs</span>
          <strong>{visibleScenarios.length}</strong>
        </article>
      </div>

      {error ? (
        <section className="error-banner" role="alert">
          <p className="eyebrow">Attention</p>
          <strong>{error}</strong>
        </section>
      ) : null}

      <main className="showcase-grid">
        <aside className="scenario-pane">
          <div className="pane-heading">
            <p className="eyebrow">Scenario registry</p>
            <h2>Subsystem packs</h2>
            <p className="pane-heading__body">Track stable and experimental proof points without rewriting the shell.</p>
          </div>
          <div className="scenario-list">
            {visibleScenarios.map((entry) => {
              const selected = entry.manifest.id === selectedScenario?.manifest.id;
              return (
                <button
                  key={entry.manifest.id}
                  type="button"
                  className={`scenario-list__item ${selected ? "scenario-list__item--selected" : ""} ${
                    entry.availability.available ? "scenario-list__item--available" : "scenario-list__item--blocked"
                  }`}
                  onClick={() => onSelectScenario(entry.manifest.id)}
                >
                  <div className="scenario-list__row">
                    <h3>{entry.manifest.title}</h3>
                    <span className={`maturity-pill maturity-pill--${entry.manifest.maturity}`}>
                      {entry.manifest.maturity}
                    </span>
                  </div>
                  <div className="scenario-list__availability">
                    <span
                      className={`availability-pill ${
                        entry.availability.available ? "availability-pill--ready" : "availability-pill--blocked"
                      }`}
                    >
                      {entry.availability.available ? "Ready" : "Capability gated"}
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
            <p className="pane-heading__body">
              Run packs against the current binary and inspect the exact output the scenario contracts assert on.
            </p>
          </div>
          <section className="run-status">
            <div>
              <p className="eyebrow">Execution state</p>
              <h3>{selectedRunVisible ? "Latest run loaded" : "Waiting for first execution"}</h3>
            </div>
            <div className="run-status__chips">
              <span className={`status-pill ${selectedRunVisible ? `status-pill--${selectedRunVisible.status}` : "status-pill--skipped"}`}>
                {selectedRunVisible?.status ?? "not run"}
              </span>
              {selectedRunVisible ? <span className="run-status__timestamp">Started {formatTimestamp(selectedRunVisible.startedAt)}</span> : null}
              {selectedRunVisible ? <span className="run-status__timestamp">Finished {formatTimestamp(selectedRunVisible.finishedAt)}</span> : null}
            </div>
          </section>
          {selectedRunVisible ? (
            <>
              {selectedRunVisible.summaryEvidence ? (
                <article className="summary-evidence">
                  <h3>Stable summary evidence</h3>
                  <pre>{formatValue(selectedRunVisible.summaryEvidence)}</pre>
                </article>
              ) : null}
              <div className="step-stack">
                {selectedRunVisible.steps.map((step) => (
                  <ScenarioStepCard key={step.id} step={step} />
                ))}
              </div>
            </>
          ) : (
            <div className="planned-steps">
              <article className="planned-intro">
                <p className="eyebrow">Ready state</p>
                <h3>Execution panels will fill in after a live run.</h3>
                <p>
                  The sequence below is the current contract for this scenario. Each step maps to machine-checked
                  evidence once you execute the pack.
                </p>
              </article>
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
            <p className="pane-heading__body">
              This rail keeps the product argument attached to the exact scenario you are inspecting.
            </p>
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
  const [theme, setTheme] = useState<ThemeMode>(readInitialTheme);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setError(null);
    fetchState()
      .then((nextState) => {
        if (cancelled) return;
        setState(nextState);
        startTransition(() => {
          setSelectedScenarioId((current) => current ?? nextState.scenarios[0]?.manifest.id ?? null);
        });
      })
      .catch((nextError) => {
        if (!cancelled) {
          setError(nextError instanceof Error ? nextError.message : "Unable to load showcase state.");
        }
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

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.colorScheme = theme;
    try {
      window.localStorage.setItem(THEME_STORAGE_KEY, theme);
    } catch {
      // Keep the UI usable even if storage is unavailable.
    }
  }, [theme]);

  useEffect(() => {
    const visibleScenarios = releaseMode
      ? (state?.scenarios ?? []).filter((entry) => entry.manifest.maturity !== "experimental")
      : (state?.scenarios ?? []);
    if (visibleScenarios.length === 0) {
      return;
    }
    const selectionVisible = visibleScenarios.some((entry) => entry.manifest.id === selectedScenarioId);
    if (!selectionVisible) {
      startTransition(() => {
        setSelectedScenarioId(visibleScenarios[0]?.manifest.id ?? null);
        setRunResult(null);
      });
    }
  }, [releaseMode, selectedScenarioId, state?.scenarios]);

  async function handleResetSession() {
    setLoading(true);
    setError(null);
    try {
      const nextState = await resetSession();
      setState(nextState);
      setRunResult(null);
      startTransition(() => {
        setSelectedScenarioId(nextState.scenarios[0]?.manifest.id ?? null);
      });
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "Unable to reset the showcase session.");
    } finally {
      setLoading(false);
    }
  }

  async function handleRunScenario() {
    const visibleScenarios = releaseMode
      ? (state?.scenarios ?? []).filter((entry) => entry.manifest.maturity !== "experimental")
      : (state?.scenarios ?? []);
    const selectedScenario =
      visibleScenarios.find((entry) => entry.manifest.id === selectedScenarioId) ?? visibleScenarios[0] ?? null;
    if (!selectedScenario) {
      return;
    }
    setRunning(true);
    setError(null);
    try {
      const nextResult = await runScenario(selectedScenario.manifest.id);
      setRunResult(nextResult);
      if (selectedScenario.manifest.id !== selectedScenarioId) {
        startTransition(() => {
          setSelectedScenarioId(selectedScenario.manifest.id);
        });
      }
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "Unable to execute the selected scenario.");
    } finally {
      setRunning(false);
    }
  }

  return (
    <ShowcaseDashboard
      state={state}
      selectedScenarioId={selectedScenarioId}
      releaseMode={releaseMode}
      runResult={runResult}
      theme={theme}
      error={error}
      loading={loading}
      running={running}
      onSelectScenario={(scenarioId) => {
        startTransition(() => {
          setSelectedScenarioId(scenarioId);
          setRunResult(null);
          setError(null);
        });
      }}
      onThemeChange={setTheme}
      onToggleReleaseMode={setReleaseMode}
      onResetSession={handleResetSession}
      onRunScenario={handleRunScenario}
    />
  );
}
