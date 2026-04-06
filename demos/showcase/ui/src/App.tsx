import { startTransition, useDeferredValue, useEffect, useState } from "react";

import type { DemoStateResponse, ScenarioRunResult, ScenarioStepResult } from "../../shared/contracts.js";
import { fetchState, resetSession, runScenario } from "./api.js";

type ThemeMode = "dark" | "light";
type TabId = "evidence" | "context";
type LaunchCardId = "edge-story" | "maintenance-lane" | "compiler-lane";

const THEME_STORAGE_KEY = "sydra-showcase-theme";
const LAUNCH_CARDS_COOKIE = "sydra_showcase_launch_cards";
const LAUNCH_CARDS_COOKIE_VALUE = "hidden";
const LAUNCH_CARDS_COOKIE_MAX_AGE = 60 * 60 * 24 * 365;

interface LaunchCardDefinition {
  id: LaunchCardId;
  order: string;
  eyebrow: string;
  title: string;
  body: string;
  bullets: string[];
  ctaLabel: string;
  scenarioId: string;
}

const LAUNCH_CARDS: LaunchCardDefinition[] = [
  {
    id: "edge-story",
    order: "01",
    eyebrow: "Incident setup",
    title: "Edge fleet story",
    body: "This demo starts with three local repos: edge-east, edge-west, and HQ. Edge-east receives a bad rollout and becomes the problem site; the rest of the fleet gives you the control group.",
    bullets: [
      "Baseline telemetry is seeded into both edge sites before the incident lands.",
      "Only edge-east picks up the bad state, so CAS history has something concrete to investigate and reverse.",
      "Start with history and recovery to diff the checkpoint, inspect the reflog, and move heads/main back to the safe commit.",
    ],
    ctaLabel: "start here",
    scenarioId: "cas-history",
  },
  {
    id: "maintenance-lane",
    order: "02",
    eyebrow: "Operational proof",
    title: "Ops and exchange lane",
    body: "Once the rollback story makes sense, the next question is whether the repository remains inspectable, repairable, and movable under operational pressure.",
    bullets: [
      "Pack, fsck, GC, and vacuum show the storage stays healthy after the incident and rollback path.",
      "Bundle, clone, fetch, and push show that the same state can move toward HQ without inventing a separate replication demo.",
      "This is the part of the story where SydraDB stops looking like a database file and starts looking like an operational data model.",
    ],
    ctaLabel: "continue",
    scenarioId: "cas-maintenance",
  },
  {
    id: "compiler-lane",
    order: "03",
    eyebrow: "Query visibility",
    title: "Compiler evidence lane",
    body: "The same fleet fixtures also power the sydraQL and compiler scenarios, so query execution evidence stays attached to the operational story instead of drifting into a synthetic benchmark.",
    bullets: [
      "Use the compiler scenarios to inspect compiled, shadow, and legacy behavior on real seeded edge data.",
      "Trace ids, execution mode, and fallback fields make the engine's decision path visible while compiler work is still moving quickly.",
      "This is where the showcase answers not just what SydraDB stores, but how it reasons about the fleet data in flight.",
    ],
    ctaLabel: "inspect",
    scenarioId: "sydraql-compiler",
  },
];

function readInitialTheme(): ThemeMode {
  if (typeof window === "undefined") return "dark";
  try {
    const stored = window.localStorage.getItem(THEME_STORAGE_KEY);
    return stored === "light" || stored === "dark" ? stored : "dark";
  } catch {
    return "dark";
  }
}

function hasHiddenLaunchCardsCookie(): boolean {
  if (typeof document === "undefined") return false;
  return document.cookie
    .split(";")
    .map((entry) => entry.trim())
    .some((entry) => entry === `${LAUNCH_CARDS_COOKIE}=${LAUNCH_CARDS_COOKIE_VALUE}`);
}

function persistLaunchCardsHidden(): void {
  if (typeof document === "undefined") return;
  document.cookie = [
    `${LAUNCH_CARDS_COOKIE}=${LAUNCH_CARDS_COOKIE_VALUE}`,
    "Path=/",
    `Max-Age=${LAUNCH_CARDS_COOKIE_MAX_AGE}`,
    "SameSite=Lax",
  ].join("; ");
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
  launchCardsVisible: boolean;
  dismissedLaunchCardIds: LaunchCardId[];
  loading: boolean;
  running: boolean;
  onSelectScenario: (id: string) => void;
  onThemeChange: (theme: ThemeMode) => void;
  onToggleReleaseMode: (value: boolean) => void;
  onToggleLaunchCards: () => void;
  onDismissLaunchCard: (cardId: LaunchCardId) => void;
  onDismissAllLaunchCards: () => void;
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
  launchCardsVisible,
  dismissedLaunchCardIds,
  loading,
  running,
  onSelectScenario,
  onThemeChange,
  onToggleReleaseMode,
  onToggleLaunchCards,
  onDismissLaunchCard,
  onDismissAllLaunchCards,
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
  const visibleLaunchCards = LAUNCH_CARDS.filter((card) => !dismissedLaunchCardIds.includes(card.id));

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

      <div className="launch-notes-anchor">
        {launchCardsVisible && visibleLaunchCards.length > 0 && (
          <div className="launch-notes" role="dialog" aria-label="Launch notes">
            <div className="launch-notes__header">
              <div>
                <div className="launch-notes__eyebrow">First launch</div>
                <div className="launch-notes__title">Edge fleet guide</div>
                <p className="launch-notes__summary">
                  Follow the incident from edge-east failure to recovery, then widen out into maintenance, sync, and
                  compiler visibility.
                </p>
              </div>
              <button
                type="button"
                className="launch-notes__dismiss-all"
                onClick={onDismissAllLaunchCards}
                aria-label="Dismiss launch notes"
              >
                dismiss
              </button>
            </div>

            <div className="launch-notes__stack">
              {visibleLaunchCards.map((card) => {
                const scenario = state?.scenarios.find((entry) => entry.manifest.id === card.scenarioId) ?? null;
                const available = scenario?.availability.available ?? false;
                return (
                  <section key={card.id} className="launch-card">
                    <div className="launch-card__header">
                      <div className="launch-card__heading">
                        <span className="launch-card__order">{card.order}</span>
                        <div>
                          <div className="launch-card__eyebrow">{card.eyebrow}</div>
                          <span className="launch-card__title">{card.title}</span>
                        </div>
                      </div>
                      <button
                        type="button"
                        className="launch-card__dismiss"
                        onClick={() => onDismissLaunchCard(card.id)}
                        aria-label={`Dismiss ${card.title}`}
                      >
                        ×
                      </button>
                    </div>
                    <p className="launch-card__body">{card.body}</p>
                    <ul className="launch-card__list">
                      {card.bullets.map((bullet) => (
                        <li key={bullet}>{bullet}</li>
                      ))}
                    </ul>
                    <div className="launch-card__footer">
                      <span className={`tag ${available ? "tag--ready" : "tag--blocked"}`}>
                        {available ? "ready" : "blocked"}
                      </span>
                      <button
                        type="button"
                        className="btn btn--small"
                        disabled={!scenario || !available}
                        onClick={() => {
                          onSelectScenario(card.scenarioId);
                          setActiveTab("evidence");
                        }}
                      >
                        {card.ctaLabel}
                      </button>
                    </div>
                  </section>
                );
              })}
            </div>
          </div>
        )}

        <button type="button" className="launch-notes-toggle" onClick={onToggleLaunchCards}>
          {launchCardsVisible ? "Hide launch notes" : "Show launch notes"}
        </button>
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
  const [launchCardsVisible, setLaunchCardsVisible] = useState(() => !hasHiddenLaunchCardsCookie());
  const [dismissedLaunchCardIds, setDismissedLaunchCardIds] = useState<LaunchCardId[]>([]);
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
    if (launchCardsVisible && dismissedLaunchCardIds.length >= LAUNCH_CARDS.length) {
      persistLaunchCardsHidden();
      setLaunchCardsVisible(false);
      setDismissedLaunchCardIds([]);
    }
  }, [dismissedLaunchCardIds, launchCardsVisible]);

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
      launchCardsVisible={launchCardsVisible}
      dismissedLaunchCardIds={dismissedLaunchCardIds}
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
      onToggleLaunchCards={() => {
        setLaunchCardsVisible((current) => {
          if (current) {
            persistLaunchCardsHidden();
            setDismissedLaunchCardIds([]);
            return false;
          }
          setDismissedLaunchCardIds([]);
          return true;
        });
      }}
      onDismissLaunchCard={(cardId) => {
        setDismissedLaunchCardIds((current) =>
          current.includes(cardId) ? current : [...current, cardId],
        );
      }}
      onDismissAllLaunchCards={() => {
        persistLaunchCardsHidden();
        setDismissedLaunchCardIds([]);
        setLaunchCardsVisible(false);
      }}
      onResetSession={handleResetSession}
      onRunScenario={handleRunScenario}
    />
  );
}
