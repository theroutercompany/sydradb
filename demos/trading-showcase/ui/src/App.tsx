import { startTransition, useEffect, useMemo, useState } from "react";

import type { DemoScenarioSummary, DemoStateResponse, EvidencePanel, ScenarioRunResult, ScenarioStepResult } from "../../shared/contracts.js";
import { fetchState, resetSession, runScenario } from "./api.js";

type ThemeMode = "dark" | "light";
type ViewTab = "story" | "context";

const THEME_STORAGE_KEY = "sydra-trading-showcase-theme";

const SCENARIO_GUIDES: Record<string, { whatItProves: string; whereSydraDbSits: string; whyItMatters: string }> = {
  "feed-and-schema": {
    whatItProves:
      "A gateway, feed handler, or post-trade service can write structured market rows into SydraDB today and query them back in the same shape operators expect.",
    whereSydraDbSits:
      "In this story, SydraDB sits behind a market-data producer. The producer writes trade and quote rows over HTTP, and downstream readers query the local store instead of scraping logs or rebuilding state from raw files.",
    whyItMatters:
      "This is the adoption question non-specialists ask first: what goes in, what comes back out, and how much integration glue is needed before the database is useful.",
  },
  "bars-and-signals": {
    whatItProves:
      "Trading definitions are not abstract metadata. The bar-policy, rollup, and signal APIs all create runtime state that SydraDB can expose directly.",
    whereSydraDbSits:
      "Here SydraDB is not just storing raw rows. It is also acting as the local engine that materializes derived trading state and exposes whether those definitions are active, stalled, or emitting.",
    whyItMatters:
      "For traders, researchers, and platform teams, this is the difference between a passive time-series store and an operational runtime that can host market definitions close to the data.",
  },
  "analysis-and-replay": {
    whatItProves:
      "A corrected market slice can be compared across storage revisions, so post-trade analysis can be rerun against what the desk saw before and after a fix.",
    whereSydraDbSits:
      "SydraDB is still the local market-data engine first, but the storage model keeps enough revision history that analysis can be compared across named heads instead of relying on external backup copies.",
    whyItMatters:
      "This is where the trading story becomes operationally different from dropping rows into SQLite. A corrected feed change can be inspected as a storage revision and compared analytically without rebuilding a second pipeline.",
  },
};

const SCENARIO_ORDER = ["feed-and-schema", "bars-and-signals", "analysis-and-replay"];

function readPath(target: unknown, path: string | undefined): unknown {
  if (!path || path.length === 0) {
    return target;
  }
  return path.split(".").reduce<unknown>((current, key) => {
    if (current == null) return undefined;
    if (Array.isArray(current)) {
      const index = Number(key);
      return Number.isInteger(index) ? current[index] : undefined;
    }
    if (typeof current === "object") {
      return (current as Record<string, unknown>)[key];
    }
    return undefined;
  }, target);
}

function formatPanelValue(panel: EvidencePanel, step: ScenarioStepResult): string {
  const value = readPath(step.output, panel.sourcePath);
  if (panel.kind === "command") {
    return step.command ?? step.textOutput ?? "";
  }
  if (typeof value === "string") {
    return value;
  }
  return JSON.stringify(value ?? step.output ?? {}, null, 2);
}

function formatStepLabel(step: ScenarioStepResult["kind"]): string {
  switch (step) {
    case "http_request":
      return "HTTP";
    case "shell_command":
      return "Shell";
    case "cas_command":
      return "Storage";
    case "server_control":
      return "Lifecycle";
    case "wait":
      return "Settle";
    case "metrics_snapshot":
      return "Metrics";
    case "query_range":
      return "Range";
    case "sydraql_query":
      return "sydraQL";
  }
}

function sortScenarios(scenarios: DemoScenarioSummary[]) {
  return [...scenarios].sort((a, b) => {
    const aIndex = SCENARIO_ORDER.indexOf(a.manifest.id);
    const bIndex = SCENARIO_ORDER.indexOf(b.manifest.id);
    return (aIndex === -1 ? 999 : aIndex) - (bIndex === -1 ? 999 : bIndex);
  });
}

export default function App() {
  const [state, setState] = useState<DemoStateResponse | null>(null);
  const [selectedScenarioId, setSelectedScenarioId] = useState<string | null>(null);
  const [runResult, setRunResult] = useState<ScenarioRunResult | null>(null);
  const [theme, setTheme] = useState<ThemeMode>(() => {
    try {
      return window.localStorage.getItem(THEME_STORAGE_KEY) === "light" ? "light" : "dark";
    } catch {
      return "dark";
    }
  });
  const [tab, setTab] = useState<ViewTab>("story");
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchState()
      .then((nextState) => {
        if (cancelled) {
          return;
        }
        const ordered = sortScenarios(nextState.scenarios);
        setState({ ...nextState, scenarios: ordered });
        startTransition(() => {
          setSelectedScenarioId(ordered[0]?.manifest.id ?? null);
        });
      })
      .catch((nextError) => {
        if (!cancelled) {
          setError(nextError instanceof Error ? nextError.message : "Unable to load the trading showcase.");
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
    } catch {}
  }, [theme]);

  const scenarios = state?.scenarios ?? [];
  const selectedScenario = useMemo(
    () => scenarios.find((scenario) => scenario.manifest.id === selectedScenarioId) ?? scenarios[0] ?? null,
    [scenarios, selectedScenarioId],
  );
  const guide = selectedScenario ? SCENARIO_GUIDES[selectedScenario.manifest.id] : null;

  async function handleReset() {
    setLoading(true);
    setError(null);
    try {
      const nextState = await resetSession();
      const ordered = sortScenarios(nextState.scenarios);
      setState({ ...nextState, scenarios: ordered });
      setRunResult(null);
      startTransition(() => setSelectedScenarioId(ordered[0]?.manifest.id ?? null));
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "Unable to reset the trading showcase.");
    } finally {
      setLoading(false);
    }
  }

  async function handleRun() {
    if (!selectedScenario) {
      return;
    }
    setRunning(true);
    setError(null);
    try {
      const result = await runScenario(selectedScenario.manifest.id);
      setRunResult(result);
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : "Unable to run the trading scenario.");
    } finally {
      setRunning(false);
    }
  }

  return (
    <div className="trading-app-shell">
      <header className="trading-app-header">
        <div>
          <p className="eyebrow">SydraDB trading showcase</p>
          <h1>Market data in, runtime state out, revisions still explainable</h1>
          <p className="lead">
            This walkthrough is for traders and researchers evaluating SydraDB as a local trading engine,
            not just a place to park rows.
          </p>
        </div>
        <div className="header-actions">
          <button type="button" className="ghost-button" onClick={() => setTheme(theme === "dark" ? "light" : "dark")}>
            {theme === "dark" ? "Light" : "Dark"}
          </button>
          <button type="button" className="ghost-button" onClick={handleReset} disabled={loading || running}>
            Reset session
          </button>
          <button
            type="button"
            className="primary-button"
            onClick={handleRun}
            disabled={loading || running || !selectedScenario || !selectedScenario.availability.available}
          >
            {running ? "Running..." : "Run scenario"}
          </button>
        </div>
      </header>

      {error ? <div className="error-banner">{error}</div> : null}

      <main className="trading-layout">
        <aside className="scenario-rail">
          <h2>Scenario groups</h2>
          {scenarios.map((scenario) => (
            <button
              key={scenario.manifest.id}
              type="button"
              className={`scenario-card ${scenario.manifest.id === selectedScenario?.manifest.id ? "selected" : ""} ${scenario.availability.available ? "" : "blocked"}`}
              onClick={() => {
                startTransition(() => {
                  setSelectedScenarioId(scenario.manifest.id);
                  setRunResult(null);
                  setError(null);
                });
              }}
            >
              <span className="scenario-title">{scenario.manifest.title}</span>
              <span className="scenario-summary">{scenario.manifest.summary}</span>
              {scenario.availability.available ? (
                <span className="scenario-status available">Ready</span>
              ) : (
                <span className="scenario-status blocked">Blocked: {scenario.availability.missingCapabilities.join(", ")}</span>
              )}
            </button>
          ))}
        </aside>

        <section className="primary-workspace">
          {selectedScenario ? (
            <>
              <div className="hero-card">
                <div>
                  <p className="eyebrow">Guided trading walkthrough</p>
                  <h2>{selectedScenario.manifest.title}</h2>
                  <p>{selectedScenario.manifest.summary}</p>
                </div>
                <div className="hero-note">
                  <h3>Where SydraDB sits here</h3>
                  <p>{guide?.whereSydraDbSits}</p>
                </div>
              </div>

              {runResult ? (
                <div className="run-surface">
                  <div className="summary-strip">
                    <div>
                      <span className="strip-label">What this proves</span>
                      <p>{guide?.whatItProves}</p>
                    </div>
                    <div>
                      <span className="strip-label">Why it matters</span>
                      <p>{guide?.whyItMatters}</p>
                    </div>
                  </div>

                  {runResult.summaryEvidence ? (
                    <div className="summary-evidence">
                      <h3>Fast read</h3>
                      <pre>{JSON.stringify(runResult.summaryEvidence, null, 2)}</pre>
                    </div>
                  ) : null}

                  <div className="step-stack">
                    {runResult.steps.map((step) => (
                      <article key={step.id} className={`step-card ${step.status}`}>
                        <header>
                          <div>
                            <span className="step-kind">{formatStepLabel(step.kind)}</span>
                            <h3>{step.title}</h3>
                            <p>{step.summary}</p>
                          </div>
                          <span className={`step-status ${step.status}`}>{step.status}</span>
                        </header>
                        <div className="panel-grid">
                          {(selectedScenario.manifest.steps.find((entry) => entry.id === step.id)?.evidencePanels ?? []).map((panel) => (
                            <section key={panel.id} className="evidence-panel">
                              <h4>{panel.title}</h4>
                              {panel.description ? <p>{panel.description}</p> : null}
                              <pre>{formatPanelValue(panel, step)}</pre>
                            </section>
                          ))}
                        </div>
                      </article>
                    ))}
                  </div>
                </div>
              ) : (
                <div className="empty-state">
                  <h3>Run the selected scenario</h3>
                  <p>
                    Each lane runs real `sydradb` processes against deterministic market fixtures. The goal is to explain how
                    a trading team would actually use SydraDB: write market rows, define runtime behavior, then inspect grouped
                    analysis and storage-backed revisions.
                  </p>
                </div>
              )}
            </>
          ) : (
            <div className="empty-state">
              <h3>Loading trading scenarios…</h3>
            </div>
          )}
        </section>

        <aside className="context-rail">
          <div className="tab-row">
            <button type="button" className={tab === "story" ? "active" : ""} onClick={() => setTab("story")}>
              Story
            </button>
            <button type="button" className={tab === "context" ? "active" : ""} onClick={() => setTab("context")}>
              Context
            </button>
          </div>

          {selectedScenario ? (
            tab === "story" ? (
              <div className="context-card">
                <h3>How to read this lane</h3>
                <p>{guide?.whatItProves}</p>
                <ul>
                  <li>SydraDB is the local market-data engine first. The raw writes and grouped reads matter before storage internals enter the story.</li>
                  <li>The internal storage model matters once corrected data, reruns, or rollback questions appear.</li>
                  <li>For managers and mid-level engineers, the fastest read is whether the output changed in a way that matches the scenario story.</li>
                </ul>
              </div>
            ) : (
              <div className="context-card">
                <h3>Why not SQLite here?</h3>
                <ul>
                  {selectedScenario.manifest.whySQLiteFallsShort.map((point) => (
                    <li key={point}>{point}</li>
                  ))}
                </ul>
                <h4>Capabilities</h4>
                <ul className="capability-list">
                  {Object.entries(state?.capabilities ?? {}).map(([name, enabled]) => (
                    <li key={name} className={enabled ? "enabled" : "disabled"}>
                      <span>{name}</span>
                      <strong>{enabled ? "yes" : "no"}</strong>
                    </li>
                  ))}
                </ul>
              </div>
            )
          ) : null}
        </aside>
      </main>
    </div>
  );
}
