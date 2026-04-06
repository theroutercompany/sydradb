export type SubsystemTag = string;

export type ScenarioMaturity = "experimental" | "alpha" | "candidate";

export type EvidencePanelKind =
  | "json"
  | "command"
  | "metrics"
  | "query-stats"
  | "rows"
  | "note";

export type AssertionOperator =
  | "truthy"
  | "equals"
  | "includes"
  | "gte"
  | "minLength";

export interface StepAssertion {
  path: string;
  operator: AssertionOperator;
  value?: unknown;
  message?: string;
}

export interface EvidencePanel {
  id: string;
  title: string;
  kind: EvidencePanelKind;
  sourcePath?: string;
  description?: string;
}

export interface ScenarioStepBase {
  id: string;
  title: string;
  summary: string;
  evidencePanels: EvidencePanel[];
  assertions?: StepAssertion[];
}

export interface CasCommandStep extends ScenarioStepBase {
  kind: "cas_command";
  workspace: string;
  args: string[];
  json?: boolean;
}

export interface ShellCommandStep extends ScenarioStepBase {
  kind: "shell_command";
  workspace: string;
  args: string[];
}

export interface SydraqlStep extends ScenarioStepBase {
  kind: "sydraql_query";
  workspace: string;
  query: string;
}

export interface QueryRangeStep extends ScenarioStepBase {
  kind: "query_range";
  workspace: string;
  payload: Record<string, unknown>;
}

export interface MetricsStep extends ScenarioStepBase {
  kind: "metrics_snapshot";
  workspace: string;
  counters: string[];
}

export interface ServerControlStep extends ScenarioStepBase {
  kind: "server_control";
  workspace: string;
  action: "start" | "stop" | "restart";
}

export interface WaitStep extends ScenarioStepBase {
  kind: "wait";
  durationMs: number;
}

export interface HttpRequestStep extends ScenarioStepBase {
  kind: "http_request";
  workspace: string;
  method: "GET" | "POST";
  path: string;
  body?: string | Record<string, unknown>;
  contentType?: string;
  responseType?: "json" | "text";
}

export type ScenarioStep =
  | CasCommandStep
  | ShellCommandStep
  | SydraqlStep
  | QueryRangeStep
  | MetricsStep
  | ServerControlStep
  | WaitStep
  | HttpRequestStep;

export interface ScenarioManifest {
  schemaVersion: 1;
  id: string;
  title: string;
  summary: string;
  maturity: ScenarioMaturity;
  subsystems: SubsystemTag[];
  requiredCapabilities: string[];
  minimumOutputs: string[];
  seedRoutine: string;
  cleanupRoutine: string;
  whySQLiteFallsShort: string[];
  steps: ScenarioStep[];
}

export interface ScenarioAvailability {
  id: string;
  available: boolean;
  missingCapabilities: string[];
}

export interface DemoScenarioSummary {
  manifest: ScenarioManifest;
  availability: ScenarioAvailability;
}

export interface DemoStateResponse {
  sessionId: string;
  sessionRoot: string;
  repoRoot: string;
  binaryPath: string;
  scenarios: DemoScenarioSummary[];
  capabilities: Record<string, boolean>;
}

export interface StepAssertionResult {
  path: string;
  operator: AssertionOperator;
  expected?: unknown;
  actual?: unknown;
  passed: boolean;
  message?: string;
}

export interface ScenarioStepResult {
  id: string;
  title: string;
  summary: string;
  kind: ScenarioStep["kind"];
  status: "passed" | "failed" | "skipped";
  command?: string;
  output?: unknown;
  textOutput?: string;
  assertions: StepAssertionResult[];
}

export interface ScenarioRunResult {
  scenarioId: string;
  status: "passed" | "failed" | "blocked";
  startedAt: string;
  finishedAt: string;
  sessionId: string;
  workspaceRoot: string;
  summaryEvidence?: Record<string, unknown>;
  steps: ScenarioStepResult[];
}
