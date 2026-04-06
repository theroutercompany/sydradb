import { startTransition, useDeferredValue, useEffect, useState } from "react";

import type { DemoStateResponse, EvidencePanel, ScenarioRunResult, ScenarioStepResult } from "../../shared/contracts.js";
import { fetchState, resetSession, runScenario } from "./api.js";

type ThemeMode = "dark" | "light";
type TabId = "evidence" | "context" | "model";
type LaunchCardId = "edge-story" | "maintenance-lane" | "compiler-lane";

const THEME_STORAGE_KEY = "sydra-showcase-theme";
const CORE_ROUTE = "/core";
const LAUNCH_CARDS_COOKIE = "sydra_showcase_launch_cards";
const LAUNCH_CARDS_COOKIE_VALUE = "hidden";
const LAUNCH_CARDS_COOKIE_MAX_AGE = 60 * 60 * 24 * 365;
const DEFAULT_TRADING_SHOWCASE_PORT = import.meta.env.VITE_TRADING_SHOWCASE_PORT ?? "4277";

function resolveTradingShowcaseUrl() {
  if (import.meta.env.VITE_TRADING_SHOWCASE_URL) {
    return import.meta.env.VITE_TRADING_SHOWCASE_URL;
  }
  if (typeof window === "undefined") {
    return `http://127.0.0.1:${DEFAULT_TRADING_SHOWCASE_PORT}/`;
  }
  return `${window.location.protocol}//${window.location.hostname}:${DEFAULT_TRADING_SHOWCASE_PORT}/`;
}

const TRADING_SHOWCASE_URL = resolveTradingShowcaseUrl();

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

interface ScenarioReadingGuide {
  story: string;
  manager: string;
  engineer: string;
  operator: string;
  summaryEvidence: string;
}

interface StepReadingGuide {
  meaning: string;
  lookFor: string;
  managerLens: string;
  operatorLens: string;
}

interface ScenarioModelGuide {
  focus: string;
  operatorQuestion: string;
}

const LAUNCH_CARDS: LaunchCardDefinition[] = [
  {
    id: "edge-story",
    order: "01",
    eyebrow: "What goes in",
    title: "Local telemetry at the edge",
    body: "Think of SydraDB here as the local time-series store behind each gateway or service. In the demo, edge-east, edge-west, and HQ each run their own SydraDB storage instance and ingest tagged power telemetry.",
    bullets: [
      "Applications, collectors, or gateway processes write tagged numeric points into SydraDB over `/api/v1/ingest` or the CLI ingest path.",
      "Queries come back through range APIs or sydraQL, so the database is useful before anyone touches CAS internals.",
      "Edge-east later takes on bad state, which gives the demo a realistic storage problem to inspect and recover from.",
    ],
    ctaLabel: "see incident",
    scenarioId: "cas-history",
  },
  {
    id: "maintenance-lane",
    order: "02",
    eyebrow: "What ops gets",
    title: "Recoverable and inspectable storage",
    body: "Once the data has landed, SydraDB gives operators and mid-level engineers a storage model they can inspect, repair, roll back, and move without treating the database like a black box.",
    bullets: [
      "History and recovery show what changed and how the active storage head can move back to a safe checkpoint.",
      "Pack, fsck, GC, vacuum, bundle, clone, fetch, and push show that the same storage stays healthy and movable after the incident.",
      "This is the point where SydraDB stops looking like just another embedded database file and starts looking like an operational storage model.",
    ],
    ctaLabel: "see ops lane",
    scenarioId: "cas-maintenance",
  },
  {
    id: "compiler-lane",
    order: "03",
    eyebrow: "What developers see",
    title: "Queries with visible execution paths",
    body: "The same fleet data also drives sydraQL and compiler scenarios, so developers can see not just query answers but how the engine executed them.",
    bullets: [
      "Trace ids, execution mode, and fallback fields make the query path explainable to engineers and SREs.",
      "Compiled mode and shadow verification let the team roll out query work without going blind, while fallback fields show when legacy execution had to take over.",
      "This is where the demo answers not just what SydraDB stores, but how it behaves while serving that data.",
    ],
    ctaLabel: "see query lane",
    scenarioId: "sydraql-compiler",
  },
];

const SCENARIO_READING_GUIDES: Record<string, ScenarioReadingGuide> = {
  "cas-history": {
    story:
      "This run is the most relatable operational story in the showcase: one site in the fleet takes on a bad state, the team inspects exactly what changed, and the active head is moved back to a safe checkpoint. It is incident response, but in a form mid-level engineers and managers can read as evidence instead of tribal knowledge.",
    manager:
      "Read this as proof that SydraDB can explain a production-facing problem in plain operational terms: what changed, what was rolled back, and whether the live view returned to normal.",
    engineer:
      "Read the refs, log, diff, and reflog as the storage-side timeline. Each step is showing that rollback is grounded in storage history rather than an ad hoc restore script.",
    operator:
      "Treat this like an incident drill. The important signals are that the baseline checkpoint exists, the diff shows the bad change, and the post-rollback range query confirms the bad state is no longer live.",
    summaryEvidence:
      "The summary evidence is the executive readout. It should tell you whether the rollback path completed and whether the active query view now matches the expected safe state.",
  },
  "cas-maintenance": {
    story:
      "This run asks the next practical question after recovery: can the storage still be trusted, repaired, and maintained over time? It turns the fleet story from a one-off rollback into an operational model.",
    manager:
      "Read this as long-term operability. The value is that maintenance is built into the storage model rather than bolted on around a database file.",
    engineer:
      "Use the outputs to confirm that packing, integrity checks, cleanup, and one-shot maintenance all work against the same storage state produced by the incident story.",
    operator:
      "Focus on whether fsck sees a healthy graph, whether pack finds reachable objects, and whether GC or vacuum report anything unexpectedly unreachable or deleted.",
    summaryEvidence:
      "The summary evidence is the fastest way to judge whether the storage is healthy enough to keep operating after the earlier incident path.",
  },
  "cas-sync": {
    story:
      "This run widens the story from one site to many. After state changes at the edge, the storage can be packaged, verified, cloned, fetched, and pushed toward HQ without inventing a separate replication narrative.",
    manager:
      "Read this as portability and controlled movement. The system can move state between installations with verification instead of relying on manual file copying or external choreography.",
    engineer:
      "Look for successful bundle creation and apply, plus ref and pack preservation across clone or push/fetch steps.",
    operator:
      "This is the site-to-site workflow view. The important question is whether the destination side ends up with the expected refs and verified state.",
    summaryEvidence:
      "The summary block should tell you whether state movement worked and whether the receiving side looks like the source side in the ways that matter.",
  },
  "sydraql-query": {
    story:
      "This run makes the engine explain itself while querying the same seeded fleet data. It is useful for people who are less interested in compiler internals than in whether the query path is observable and trustworthy.",
    manager:
      "Read this as runtime transparency. The engine is not just returning rows; it is exposing how it executed the work and giving the team a language for discussing quality and rollout confidence.",
    engineer:
      "Use trace ids, execution mode, scanned rows, and operator timings to understand what the engine actually did to answer the query.",
    operator:
      "Treat this as a baseline for performance and debuggability. If query behavior changes later, these are the fields you compare first.",
    summaryEvidence:
      "The summary evidence is the compact readout of what query ran, how it ran, and whether the telemetry fields needed for debugging came back intact.",
  },
  "sydraql-compiler": {
    story:
      "This run is the compiler rollout story in operational form. Instead of asking reviewers to trust compiler progress abstractly, it shows how compiled and shadow paths behave on relatable fleet data, plus when they still fall back to legacy execution.",
    manager:
      "Read this as controlled change management. The system can expose when the new path runs, when it falls back, and why, which makes rapid compiler work easier to review responsibly.",
    engineer:
      "Execution mode and fallback fields are the first things to read. They tell you whether the compiler handled the query directly or whether an older path had to take over.",
    operator:
      "This is rollout telemetry. Use it to judge whether new query paths are becoming more predictable or more fragile over time.",
    summaryEvidence:
      "The summary evidence compresses mode and fallback signals so non-specialists can tell whether the compiler run looks healthy before reading raw details.",
  },
  "engine-lifecycle": {
    story:
      "This run reframes SydraDB as a service lifecycle story, not just a persistence story. The same seeded fleet data is used to check restart behavior, recovery anchors, and post-restart query continuity.",
    manager:
      "Read this as continuity of service. The outcome should show that restart and checkpoint workflows preserve the state the team expects users to see.",
    engineer:
      "The useful comparison is before-versus-after: whether the engine restarts cleanly and whether the recovery anchor becomes visible as part of the storage story.",
    operator:
      "Read the control actions and the following verification together. A restart step matters only if the data view after restart still matches the intended state.",
    summaryEvidence:
      "The summary block is the quick answer to whether lifecycle operations preserved the expected live state.",
  },
};

const STEP_KIND_GUIDES: Record<ScenarioStepResult["kind"], StepReadingGuide> = {
  cas_command: {
    meaning:
      "This step is reading or mutating SydraDB storage through a native CAS command. It is evidence about the storage model itself, not just application output.",
    lookFor:
      "Start with the top-level counts, entries, refs, or status fields. Those are the fastest signals for whether the storage structure looks healthy.",
    managerLens:
      "For managers and non-specialists, the value here is that SydraDB can explain storage state in reviewable steps instead of hiding it behind a single opaque file.",
    operatorLens:
      "For ops or SRE readers, this is where missing refs, unexpected zero counts, integrity errors, or unreachable-object signals would show up first.",
  },
  shell_command: {
    meaning:
      "This step issues a control action through the shell path. It matters because it changes state, not because the command text itself is inherently interesting.",
    lookFor:
      "Read the next verification step together with this one. The shell command is the action; the following query or CAS output is usually the proof.",
    managerLens:
      "This shows whether the action needed during an incident or operational task is simple enough to explain and safe enough to verify.",
    operatorLens:
      "Treat this like a runbook action: focus less on the command string and more on whether the system state after it matches the intended outcome.",
  },
  sydraql_query: {
    meaning:
      "This step runs a real sydraQL query and returns both the answer and execution telemetry. It is where correctness and engine behavior meet.",
    lookFor:
      "Read rows and execution metadata together. Trace ids, execution mode, scanned rows, and timings explain how the answer was produced.",
    managerLens:
      "This is evidence that the team can talk about query quality and engine behavior without waiting for separate observability projects.",
    operatorLens:
      "Use it as a debugging baseline. If the same query later becomes slower or falls back unexpectedly, these fields show what healthy looked like.",
  },
  query_range: {
    meaning:
      "This step asks what the live data view looks like right now. It is usually the most directly relatable output because it resembles what an application or dashboard would actually consume.",
    lookFor:
      "Pay attention to the returned rows and especially the final expected value. This often proves whether rollback or restart changed the active state correctly.",
    managerLens:
      "This is the business-facing verification step because it shows whether the operational action changed the live outcome in the way the team intended.",
    operatorLens:
      "Use this as the final correctness check after a control action. If the rows are wrong here, the earlier storage steps did not land the way you need.",
  },
  metrics_snapshot: {
    meaning:
      "This step samples internal counters from the engine. It helps translate system behavior into measurable quantities rather than anecdotes.",
    lookFor:
      "Read metrics as trend signals: queue depth, flushes, or fallback counters should move in ways that match the actions already taken in the run.",
    managerLens:
      "The main takeaway is that the storage engine exposes measurable operational signals instead of requiring the team to infer behavior indirectly.",
    operatorLens:
      "Unexpected jumps, missing movement, or obviously inconsistent counters usually point to the real place to investigate next.",
  },
  server_control: {
    meaning:
      "This step changes the engine process state by starting, stopping, or restarting it. The action matters because it tests service continuity.",
    lookFor:
      "The real meaning appears in the next verification step: did the engine come back with the same expected state and query behavior?",
    managerLens:
      "This is evidence about continuity and recoverability, not just about data format correctness.",
    operatorLens:
      "Read it like a restart drill. A clean control action only counts if the subsequent validation still looks healthy.",
  },
  wait: {
    meaning:
      "This step gives the local engine time to flush or materialize the writes that just landed before the next read or analysis step runs.",
    lookFor:
      "Read it as part of the operational sequence, not as a separate feature. The real evidence is in the read or analysis step that follows.",
    managerLens:
      "This helps explain that local processing is part of the system behavior, and the demo is waiting for that state to become visible before it judges the result.",
    operatorLens:
      "Treat this like a short settle window after writes or lifecycle changes. If later reads still look wrong, the problem is not just timing.",
  },
};

const STEP_GUIDE_OVERRIDES: Record<string, Record<string, Partial<StepReadingGuide>>> = {
  "cas-history": {
    refs: {
      meaning:
        "This confirms the storage has a live named head before anyone is asked to trust the rollback story.",
      lookFor:
        "If heads/main is present, there is a concrete active pointer the rest of the incident narrative can anchor to.",
    },
    log: {
      meaning:
        "This is the storage-side timeline of the incident. It shows whether the bad change is visible as history rather than disappearing into overwritten state.",
      lookFor:
        "More than one entry means the baseline and the changed state are both visible and reviewable.",
    },
    diff: {
      meaning:
        "This isolates the difference between the safe checkpoint and the current head so reviewers can see what changed before recovery.",
    },
    rollback: {
      meaning:
        "This is the control action that moves the active head back to the known-good checkpoint.",
      lookFor:
        "Read the next range query as the proof. The command matters because it should change what the live system sees.",
    },
    "verify-rollback": {
      meaning:
        "This is the most application-facing validation step in the scenario. It checks whether the bad incident points are truly gone from the live head.",
      lookFor:
        "If the last returned value matches the baseline instead of the incident, the recovery succeeded in the view downstream systems would actually read.",
    },
    reflog: {
      meaning:
        "The reflog keeps the recovery action itself auditable. It shows that rollback is not just possible, but reviewable after the fact.",
    },
  },
  "cas-maintenance": {
    pack: {
      meaning:
        "Packing turns loose reachable objects into a more maintainable storage shape without changing the meaning of the active storage state.",
    },
    fsck: {
      meaning:
        "fsck is the direct integrity readout. It answers whether the graph still makes sense after the earlier incident and recovery path.",
    },
    gc: {
      meaning:
        "GC estimates what data is still truly reachable and what could eventually be cleaned up.",
    },
    vacuum: {
      meaning:
        "Vacuum is the combined maintenance path. It gives non-specialists a single command to associate with “make the storage healthy again.”",
    },
  },
  "sydraql-compiler": {
    compiled: {
      lookFor:
        "The first field to scan is execution_mode. If it says compiled, the new compiler path handled the query directly.",
    },
    shadow: {
      lookFor:
        "Shadow output is about rollout safety. For managers it says “we can compare paths”; for engineers it says “we can see fallback behavior clearly.”",
    },
  },
};

const SCENARIO_MODEL_GUIDES: Record<string, ScenarioModelGuide> = {
  "cas-history": {
    focus:
      "This scenario proves that an incident on edge-east is stored as history inside SydraDB itself, which is why diff, rollback, and reflog operations are meaningful in the first place.",
    operatorQuestion:
      "If a site goes bad, can I inspect the storage timeline, identify the safe checkpoint, and move the active head back without rebuilding the whole system by hand?",
  },
  "cas-maintenance": {
    focus:
      "This scenario proves that once the storage has lived through writes and recovery, it can still be packed, validated, cleaned up, and repaired as part of normal operations.",
    operatorQuestion:
      "After a recovery, does the storage remain healthy and maintainable, or do we need a second toolchain to make it trustworthy again?",
  },
  "cas-sync": {
    focus:
      "This scenario proves that the same storage state can move between edge and HQ as SydraDB state, not just as copied files or ad hoc export/import scripts.",
    operatorQuestion:
      "Can I move or clone the storage state between sites while preserving refs, packs, and verifiable history?",
  },
  "sydraql-query": {
    focus:
      "This scenario proves that the engine can explain how it answered a query against real fleet data, which helps operators and mid-level engineers debug without jumping straight into internals.",
    operatorQuestion:
      "When a query looks odd or slow, do I get enough execution evidence to understand what path the engine took?",
  },
  "sydraql-compiler": {
    focus:
      "This scenario proves that the compiler rollout is observable. Compiled and shadow paths can be reasoned about against the same seeded fleet state, and legacy fallback remains visible when the newer path does not apply.",
    operatorQuestion:
      "If a new query path is being rolled out, can I tell whether the system used it, fell back, or disagreed with an older path?",
  },
  "engine-lifecycle": {
    focus:
      "This scenario proves that the service lifecycle and the storage lifecycle line up: restart, recovery anchors, and query continuity all stay part of one operational model.",
    operatorQuestion:
      "When the service restarts or maintenance runs, does the live view stay consistent with the storage state I expect?",
  },
};

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
  if (value === undefined) return "Not available";
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

function formatTimestamp(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function getStepGuide(scenarioId: string | undefined, step: ScenarioStepResult): StepReadingGuide {
  const base = STEP_KIND_GUIDES[step.kind];
  const override = scenarioId ? STEP_GUIDE_OVERRIDES[scenarioId]?.[step.id] : undefined;

  return {
    meaning: override?.meaning ?? base.meaning,
    lookFor: override?.lookFor ?? base.lookFor,
    managerLens: override?.managerLens ?? base.managerLens,
    operatorLens: override?.operatorLens ?? base.operatorLens,
  };
}

function readValueByPath(target: unknown, path?: string): unknown {
  if (!path || path === "") {
    return target;
  }

  return path.split(".").reduce<unknown>((current, key) => {
    if (current == null) {
      return undefined;
    }
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

function getPanelValue(step: ScenarioStepResult, panel: EvidencePanel): unknown {
  if (panel.kind === "command") {
    return step.command ?? step.textOutput ?? step.output;
  }

  return readValueByPath(step.output, panel.sourcePath);
}

function StepCard({
  scenarioId,
  step,
  index,
  panels,
}: {
  scenarioId?: string;
  step: ScenarioStepResult;
  index: number;
  panels: EvidencePanel[];
}) {
  const [open, setOpen] = useState(step.status === "failed");
  const guide = getStepGuide(scenarioId, step);
  const renderedPanels = panels
    .map((panel) => ({
      panel,
      value: getPanelValue(step, panel),
    }))
    .filter(({ value }) => value !== undefined);

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
          <div className="reading-guide reading-guide--step">
            <div className="reading-guide__grid">
              <div>
                <div className="reading-guide__label">What this step means</div>
                <p className="reading-guide__text">{guide.meaning}</p>
              </div>
              <div>
                <div className="reading-guide__label">What to look for</div>
                <p className="reading-guide__text">{guide.lookFor}</p>
              </div>
              <div>
                <div className="reading-guide__label">Manager reading</div>
                <p className="reading-guide__text">{guide.managerLens}</p>
              </div>
              <div>
                <div className="reading-guide__label">Ops / SRE reading</div>
                <p className="reading-guide__text">{guide.operatorLens}</p>
              </div>
            </div>
          </div>
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
          {renderedPanels.length > 0 ? (
            <div className="evidence-panels">
              {renderedPanels.map(({ panel, value }) => (
                <div key={panel.id} className="step__output">
                  <div className="step__output-label">{panel.title}</div>
                  <pre className="step__output-pre">{formatValue(value)}</pre>
                </div>
              ))}
            </div>
          ) : (
            step.output != null && (
              <div className="step__output">
                <div className="step__output-label">Output</div>
                <pre className="step__output-pre">{formatValue(step.output)}</pre>
              </div>
            )
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
  const readingGuide = selected ? SCENARIO_READING_GUIDES[selected.manifest.id] : undefined;
  const modelGuide = selected ? SCENARIO_MODEL_GUIDES[selected.manifest.id] : undefined;

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
                <div className="main__header-text">
                  <h1 className="main__title">{selected.manifest.title}</h1>
                  <p className="main__description">{selected.manifest.summary}</p>
                </div>
                <div className="main__clarifier">
                  SydraDB is a single-node time-series database for tagged telemetry. The Git-like terms in this demo
                  describe SydraDB&apos;s internal storage model, not the application&apos;s source-code Git branch.
                </div>
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
                <button
                  type="button"
                  className={`tab ${activeTab === "model" ? "tab--active" : ""}`}
                  onClick={() => setActiveTab("model")}
                >
                  How it works
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
                        <div className="reading-guide">
                          <div className="reading-guide__header">
                            <div className="reading-guide__title">How to read this run</div>
                            <div className="reading-guide__subtitle">
                              A guided read for managers, mid-level engineers, and ops reviewers who want the story before the raw output.
                            </div>
                          </div>
                          <div className="reading-guide__story">
                            <div className="reading-guide__label">Scenario context</div>
                            <p className="reading-guide__text">
                              {readingGuide?.story ??
                                "This run is one slice of the SydraDB story shown against real seeded data. Start with the summary evidence, then use each step as proof for the claim the scenario is making."}
                            </p>
                          </div>
                          <div className="reading-guide__grid">
                            <div>
                              <div className="reading-guide__label">If you are a manager</div>
                              <p className="reading-guide__text">
                                {readingGuide?.manager ??
                                  "Focus on whether the run makes the outcome understandable, measurable, and reversible without requiring specialist storage knowledge."}
                              </p>
                            </div>
                            <div>
                              <div className="reading-guide__label">If you are an engineer</div>
                              <p className="reading-guide__text">
                                {readingGuide?.engineer ??
                                  "Read the outputs as implementation proof: what ran, what state it observed, and what the assertions validated."}
                              </p>
                            </div>
                            <div>
                              <div className="reading-guide__label">If you run ops / SRE / DevOps</div>
                              <p className="reading-guide__text">
                                {readingGuide?.operator ??
                                  "Look for healthy state transitions, explicit verification, and signals that the operational path is predictable under failure or recovery conditions."}
                              </p>
                            </div>
                            <div>
                              <div className="reading-guide__label">How to read the summary evidence</div>
                              <p className="reading-guide__text">
                                {readingGuide?.summaryEvidence ??
                                  "Treat the summary block as the short readout. It should tell you whether the scenario succeeded before you open the raw step payloads."}
                              </p>
                            </div>
                          </div>
                        </div>
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
                            <StepCard
                              key={step.id}
                              scenarioId={selected.manifest.id}
                              step={step}
                              index={i}
                              panels={selected.manifest.steps.find((manifestStep) => manifestStep.id === step.id)?.evidencePanels ?? []}
                            />
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

              {activeTab === "model" && (
                <div className="content">
                  <div className="model-grid">
                    <div className="model-section model-section--wide">
                      <h3 className="context-section__title">What SydraDB is for</h3>
                      <ul>
                        <li>SydraDB is for applications and systems that need to ingest tagged telemetry locally and query it quickly.</li>
                        <li>The current strongest story is local numeric time-series data from services, collectors, gateways, and edge software.</li>
                        <li>The differentiator is not just that it stores the data, but that the storage stays inspectable, recoverable, and syncable after the data lands.</li>
                      </ul>
                    </div>

                    <div className="model-section">
                      <h3 className="context-section__title">What SydraDB stores today</h3>
                      <ul>
                        <li>Tagged numeric time-series points: `series`, `ts`, `value`, and optional tags.</li>
                        <li>Engine state such as WAL, segments, manifests, tag snapshots, and series catalog metadata.</li>
                        <li>In CAS mode, internal storage history that enables rollback, diff, checkpoint, bundle, and maintenance workflows.</li>
                      </ul>
                    </div>

                    <div className="model-section">
                      <h3 className="context-section__title">Who uses it</h3>
                      <ul>
                        <li>Application engineers who need a local telemetry store behind a service, device, or gateway.</li>
                        <li>Platform and edge teams who need durable local storage plus later movement or recovery.</li>
                        <li>SRE, DevOps, and ops teams who need to understand what changed inside storage after a rollout or incident.</li>
                      </ul>
                    </div>

                    <div className="model-section">
                      <h3 className="context-section__title">How applications fill it</h3>
                      <ul>
                        <li>Producers emit telemetry points, which the demo seeds as NDJSON and POSTs to `POST /api/v1/ingest`.</li>
                        <li>The engine appends WAL data, updates in-memory state, and flushes segments as part of the normal time-series write path.</li>
                        <li>This means SydraDB is called first as the local write target for telemetry, not first as a maintenance tool.</li>
                      </ul>
                    </div>

                    <div className="model-section">
                      <h3 className="context-section__title">How applications and operators read it</h3>
                      <ul>
                        <li>Applications and dashboards read back through `POST /api/v1/query/range` or `POST /api/v1/sydraql`.</li>
                        <li>Operators and engineers inspect or maintain storage through `sydradb cas ...` commands and post-action verification queries.</li>
                        <li>The demo is trying to show both sides: how the store gets filled and what the storage model buys you afterwards.</li>
                      </ul>
                    </div>

                    <div className="model-section">
                      <h3 className="context-section__title">What `cas_mode = dual_write` adds</h3>
                      <ul>
                        <li>SydraDB keeps writing the regular engine state, but it also writes an immutable CAS commit chain alongside it.</li>
                        <li>The active storage snapshot is pointed to by `heads/main` inside SydraDB&apos;s own ref namespace.</li>
                        <li>That is what makes rollback, diff, reflog, pack, gc, bundle, and checkpoint operations meaningful at the storage level.</li>
                      </ul>
                    </div>

                    <div className="model-section">
                      <h3 className="context-section__title">How reads use that storage model</h3>
                      <ul>
                        <li>`metadata_read_mode = legacy` reads the older compatibility path only.</li>
                        <li>`metadata_read_mode = shadow` serves legacy answers while cross-checking them against CAS.</li>
                        <li>`metadata_read_mode = primary` serves metadata from CAS directly, which is the mode the showcase is trying to make legible.</li>
                      </ul>
                    </div>

                    <div className="model-section">
                      <h3 className="context-section__title">Why not just SQLite here?</h3>
                      <ul>
                        <li>SQLite can store measurements, but it does not give you built-in storage history, rollback, bundle, or reflog-aware maintenance semantics.</li>
                        <li>SydraDB is useful when local telemetry storage and local storage operations both matter.</li>
                        <li>The point of the demo is to show the full path: data in, queries out, and operational storage workflows in between.</li>
                      </ul>
                    </div>

                    <div className="model-section">
                      <h3 className="context-section__title">Where SydraDB sits in this demo</h3>
                      <ul>
                        <li>Each site in the story runs a local SydraDB instance: edge-east, edge-west, and HQ.</li>
                        <li>The fictional application is not talking to Git here. It is talking to SydraDB over HTTP ingest, range APIs, sydraQL, and CLI maintenance commands.</li>
                        <li>The incident story exists to make the product workflow concrete for someone evaluating whether SydraDB fits their own telemetry system.</li>
                      </ul>
                    </div>

                    <div className="model-section">
                      <h3 className="context-section__title">Why this scenario exists</h3>
                      <p className="model-section__body">{modelGuide?.focus ?? "This scenario exists to show one concrete way the time-series engine and the CAS storage model interact."}</p>
                      <div className="model-note">
                        <div className="model-note__label">Operational question</div>
                        <p className="model-note__body">
                          {modelGuide?.operatorQuestion ??
                            "What would an operator or engineer need to verify here in order to trust the storage workflow?"}
                        </p>
                      </div>
                    </div>
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

function ShowcaseCategoryHome({
  onOpenCore,
}: {
  onOpenCore: () => void;
}) {
  return (
    <div className="showcase-home-shell">
      <div className="showcase-home-hero">
        <p className="home-eyebrow">SydraDB demo launcher</p>
        <h1>Choose the story you want to walk through first</h1>
        <p>
          The core showcase stays focused on CAS, sydraQL, compiler rollout, and engine lifecycle. The trading showcase
          starts from market rows, grouped analysis, and correction-aware revision work for trading engineers.
        </p>
      </div>
      <div className="showcase-home-grid">
        <article className="showcase-home-card">
          <span className="showcase-home-label">Core platform</span>
          <h2>Storage, query, compiler, and lifecycle</h2>
          <p>
            Use this when the audience cares about why SydraDB is different from SQLite at the storage and operational
            layer.
          </p>
          <button type="button" className="home-primary-button" onClick={onOpenCore}>
            Open core showcase
          </button>
        </article>
        <article className="showcase-home-card trading">
          <span className="showcase-home-label">Trading</span>
          <h2>Market data in, analysis and revisions out</h2>
          <p>
            Use this when the audience is closer to market-data, platform, or post-trade analysis work and wants to see
            how SydraDB fits into a trading workflow.
          </p>
          <a className="home-secondary-link" href={TRADING_SHOWCASE_URL}>
            Open trading showcase
          </a>
        </article>
      </div>
    </div>
  );
}

export function CoreShowcaseApp() {
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

export default function App() {
  const [pathname, setPathname] = useState(() => window.location.pathname);

  useEffect(() => {
    const storedTheme = (() => {
      try {
        return window.localStorage.getItem(THEME_STORAGE_KEY) === "light" ? "light" : "dark";
      } catch {
        return "dark";
      }
    })();
    document.documentElement.dataset.theme = storedTheme;
    document.documentElement.style.colorScheme = storedTheme;
  }, []);

  useEffect(() => {
    const handlePopState = () => setPathname(window.location.pathname);
    window.addEventListener("popstate", handlePopState);
    return () => window.removeEventListener("popstate", handlePopState);
  }, []);

  if (pathname.startsWith(CORE_ROUTE)) {
    return <CoreShowcaseApp />;
  }

  return (
    <ShowcaseCategoryHome
      onOpenCore={() => {
        window.history.pushState({}, "", CORE_ROUTE);
        setPathname(CORE_ROUTE);
      }}
    />
  );
}
