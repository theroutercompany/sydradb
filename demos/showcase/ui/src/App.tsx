import { startTransition, useDeferredValue, useEffect, useState } from "react";

import type { DemoStateResponse, ScenarioRunResult, ScenarioStepResult } from "../../shared/contracts.js";
import { fetchState, resetSession, runScenario } from "./api.js";

type ThemeMode = "dark" | "light";
type TabId = "evidence" | "context";

const THEME_STORAGE_KEY = "sydra-showcase-theme";

function readInitialTheme(): ThemeMode {
  if (typeof window === "undefined") return "dark";
  try {
    const stored = window.localStorage.getItem(THEME_STORAGE_KEY);
    return stored === "light" || stored === "dark" ? stored : "dark";
  } catch {
    return "dark";
  }
}

function formatValue(value: unknown): string {
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

function formatTimestamp(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function StepCard({ step, index }: { step: ScenarioStepResult; index: number }) {
  const [open, setOpen] = useState(step.status === "failed");

  return (
    <div className="step">
      <div className="step__header" onClick={() => setOpen(!open)}>
        <div className="step__header-left">
          <span className="step__index">{String(index + 1).padStart(2, "0")}</span>
          <span className="step__title">{step.title}</span>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span className="step__kind">{step.kind.replaceAll("_", " ")}</span>
          <span className={`tag tag--${step.status}`}>{step.status}</span>
        </div>
      </div>
      {open && (
        <div className="step__body">
          <p className="step__summary">{step.summary}</p>
          {step.command && <pre className="step__command">{step.command}</pre>}
          {step.assertions.length > 0 && (
            <div className="assertions">
              {step.assertions.map((a) => (
                <div key={`${a.path}-${a.operator}`} className={`assertion assertion--${a.passed ? "pass" : "fail"}`}>
                  <span className="assertion__icon" />
                  <span>
                    <strong>{a.operator}</strong> {a.path || "(root)"}
                  </span>
                  {a.message && <span className="assertion__text">{a.message}</span>}
                </div>
              ))}
            </div>
          )}
          {step.output != null && (
            <div className="step__output">
              <div className="step__output-label">Output</div>
              <pre className="step__output-pre">{formatValue(step.output)}</pre>
            </div>
          )}
          {step.textOutput && (
            <div className="step__output">
              <div className="step__output-label">Command output</div>
              <pre className="step__output-pre">{step.textOutput}</pre>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

interface DashboardProps {
  state: DemoStateResponse | null;
  selectedScenarioId: string | null;
  releaseMode: boolean;
  runResult: ScenarioRunResult | null;
  theme: ThemeMode;
  error: string | null;
  loading: boolean;
  running: boolean;
  onSelectScenario: (id: string) => void;
  onThemeChange: (theme: ThemeMode) => void;
  onToggleReleaseMode: (value: boolean) => void;
  onResetSession: () => void;
  onRunScenario: () => void;
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
}: DashboardProps) {
  const [activeTab, setActiveTab] = useState<TabId>("evidence");
  const deferredReleaseMode = useDeferredValue(releaseMode);

  const visibleScenarios = deferredReleaseMode
    ? (state?.scenarios ?? []).filter((s) => s.manifest.maturity !== "experimental")
    : (state?.scenarios ?? []);

  const selected = visibleScenarios.find((s) => s.manifest.id === selectedScenarioId) ?? visibleScenarios[0] ?? null;
  const selectedRun = runResult && selected && runResult.scenarioId === selected.manifest.id ? runResult : null;
  const enabledCaps = Object.values(state?.capabilities ?? {}).filter(Boolean).length;

  return (
    <div>
      {/* ── Top bar ────────────────────────────────────── */}
      <header className="topbar">
        <div className="topbar__brand">
          <span className="topbar__logo">sydradb</span>
          <span className="topbar__separator">/</span>
          <span className="topbar__subtitle">showcase</span>
        </div>
        <div className="topbar__actions">
          <label className="toggle-label">
            <input type="checkbox" checked={releaseMode} onChange={(e) => onToggleReleaseMode(e.target.checked)} />
            <span>Release</span>
          </label>
          <button
            type="button"
            className={`btn btn--small ${theme === "dark" ? "btn--active" : ""}`}
            onClick={() => onThemeChange(theme === "dark" ? "light" : "dark")}
          >
            {theme === "dark" ? "Dark" : "Light"}
          </button>
          <button type="button" className="btn btn--small" onClick={onResetSession} disabled={loading || running}>
            Reset
          </button>
          <button
            type="button"
            className="btn btn--primary btn--small"
            onClick={onRunScenario}
            disabled={!selected || running || loading || !selected.availability.available}
          >
            {running ? "Running..." : "Run"}
          </button>
        </div>
      </header>

      {/* ── Meta bar ───────────────────────────────────── */}
      <div className="meta-bar">
        <div className="meta-bar__item">
          session <span className="meta-bar__value">{state?.sessionId?.slice(0, 8) ?? "—"}</span>
        </div>
        <div className="meta-bar__item">
          capabilities <span className="meta-bar__value">{enabledCaps}</span>
        </div>
        <div className="meta-bar__item">
          scenarios <span className="meta-bar__value">{visibleScenarios.length}</span>
        </div>
        <div className="meta-bar__item">
          binary <span className="meta-bar__value">{state?.binaryPath?.split("/").pop() ?? "—"}</span>
        </div>
      </div>

      {error && <div className="error-banner" role="alert">{error}</div>}

      {/* ── Layout ─────────────────────────────────────── */}
      <div className="layout">
        {/* ── Sidebar ────────────────────────────────── */}
        <aside className="sidebar">
          <div className="sidebar__header">
            <span className="sidebar__title">Scenarios</span>
            <span className="sidebar__count">{visibleScenarios.length}</span>
          </div>
          {visibleScenarios.map((entry) => {
            const isSelected = entry.manifest.id === selected?.manifest.id;
            return (
              <button
                key={entry.manifest.id}
                type="button"
                className={[
                  "scenario-item",
                  isSelected && "scenario-item--selected",
                  !entry.availability.available && "scenario-item--blocked",
                ]
                  .filter(Boolean)
                  .join(" ")}
                onClick={() => onSelectScenario(entry.manifest.id)}
              >
                <div className="scenario-item__top">
                  <span className="scenario-item__title">{entry.manifest.title}</span>
                  <span className={`tag tag--${entry.manifest.maturity}`}>{entry.manifest.maturity}</span>
                </div>
                <p className="scenario-item__summary">{entry.manifest.summary}</p>
                <div className="scenario-item__meta">
                  <span className={`tag ${entry.availability.available ? "tag--ready" : "tag--blocked"}`}>
                    {entry.availability.available ? "ready" : "blocked"}
                  </span>
                  {entry.manifest.subsystems.map((tag) => (
                    <span key={tag} className="tag tag--subsystem">{tag}</span>
                  ))}
                </div>
                {!entry.availability.available && (
                  <p className="scenario-item__missing">
                    missing: {entry.availability.missingCapabilities.join(", ")}
                  </p>
                )}
              </button>
            );
          })}
        </aside>

        {/* ── Main ───────────────────────────────────── */}
        <main className="main">
          {selected ? (
            <>
              <div className="main__header">
                <h1 className="main__title">{selected.manifest.title}</h1>
                <p className="main__description">{selected.manifest.summary}</p>
              </div>

              <div className="tabs">
                <button
                  type="button"
                  className={`tab ${activeTab === "evidence" ? "tab--active" : ""}`}
                  onClick={() => setActiveTab("evidence")}
                >
                  Evidence
                </button>
                <button
                  type="button"
                  className={`tab ${activeTab === "context" ? "tab--active" : ""}`}
                  onClick={() => setActiveTab("context")}
                >
                  Context
                </button>
              </div>

              {activeTab === "evidence" && (
                <>
                  <div className="run-bar">
                    <div className="run-bar__left">
                      <span className={`tag ${selectedRun ? `tag--${selectedRun.status}` : "tag--skipped"}`}>
                        {selectedRun?.status ?? "not run"}
                      </span>
                      <span>{selectedRun ? "Latest run" : "Awaiting execution"}</span>
                    </div>
                    {selectedRun && (
                      <div className="run-bar__right">
                        <span>{formatTimestamp(selectedRun.startedAt)}</span>
                        <span>→</span>
                        <span>{formatTimestamp(selectedRun.finishedAt)}</span>
                      </div>
                    )}
                  </div>

                  <div className="content">
                    {selectedRun ? (
                      <>
                        {selectedRun.summaryEvidence && (
                          <div className="summary-block">
                            <div className="summary-block__header">Summary Evidence</div>
                            <div className="summary-block__body">
                              <pre>{formatValue(selectedRun.summaryEvidence)}</pre>
                            </div>
                          </div>
                        )}
                        <div className="step-list">
                          {selectedRun.steps.map((step, i) => (
                            <StepCard key={step.id} step={step} index={i} />
                          ))}
                        </div>
                      </>
                    ) : (
                      <div className="planned-list">
                        {selected.manifest.steps.map((step, i) => (
                          <div key={step.id} className="planned-item">
                            <span className="planned-item__index">{String(i + 1).padStart(2, "0")}</span>
                            <div className="planned-item__content">
                              <div className="planned-item__title">{step.title}</div>
                              <p className="planned-item__summary">{step.summary}</p>
                            </div>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                </>
              )}

              {activeTab === "context" && (
                <div className="content">
                  <div className="context-section">
                    <h3 className="context-section__title">Why not standard SQLite?</h3>
                    <ul>
                      {selected.manifest.whySQLiteFallsShort.map((reason) => (
                        <li key={reason}>{reason}</li>
                      ))}
                    </ul>
                  </div>

                  <div className="context-section">
                    <h3 className="context-section__title">Minimum outputs</h3>
                    <ul>
                      {selected.manifest.minimumOutputs.map((output) => (
                        <li key={output}>{output}</li>
                      ))}
                    </ul>
                  </div>

                  <div className="context-section">
                    <h3 className="context-section__title">Evidence panels</h3>
                    <ul>
                      {selected.manifest.steps.flatMap((step) =>
                        step.evidencePanels.map((panel) => (
                          <li key={`${step.id}-${panel.id}`}>
                            {step.title}: {panel.title}
                          </li>
                        )),
                      )}
                    </ul>
                  </div>
                </div>
              )}
            </>
          ) : (
            <div className="empty-state">No scenarios available</div>
          )}
        </main>
      </div>
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
        if (!cancelled) setLoading(false);
      });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.colorScheme = theme;
    try { window.localStorage.setItem(THEME_STORAGE_KEY, theme); } catch {}
  }, [theme]);

  useEffect(() => {
    const visible = releaseMode
      ? (state?.scenarios ?? []).filter((s) => s.manifest.maturity !== "experimental")
      : (state?.scenarios ?? []);
    if (visible.length === 0) return;
    if (!visible.some((s) => s.manifest.id === selectedScenarioId)) {
      startTransition(() => {
        setSelectedScenarioId(visible[0]?.manifest.id ?? null);
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
    const visible = releaseMode
      ? (state?.scenarios ?? []).filter((s) => s.manifest.maturity !== "experimental")
      : (state?.scenarios ?? []);
    const target = visible.find((s) => s.manifest.id === selectedScenarioId) ?? visible[0] ?? null;
    if (!target) return;
    setRunning(true);
    setError(null);
    try {
      const result = await runScenario(target.manifest.id);
      setRunResult(result);
      if (target.manifest.id !== selectedScenarioId) {
        startTransition(() => setSelectedScenarioId(target.manifest.id));
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
      onSelectScenario={(id) => {
        startTransition(() => {
          setSelectedScenarioId(id);
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
