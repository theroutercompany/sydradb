import type {
  CasCommandStep,
  MetricsStep,
  QueryRangeStep,
  ScenarioManifest,
  ScenarioRunResult,
  ScenarioStep,
  ScenarioStepResult,
  StepAssertion,
  StepAssertionResult,
  SydraqlStep,
} from "../shared/contracts.js";
import { buildSummaryEvidence } from "./summaryEvidence.js";
import {
  type ProcessResult,
  type ScenarioSandbox,
  fetchMetricsCounters,
  postRangeQuery,
  postSydraqlQuery,
  restartWorkspaceServer,
  runBinary,
  runCasJson,
  startWorkspaceServer,
  stopWorkspaceServer,
} from "./runtime.js";

function interpolateString(template: string, vars: Record<string, string>): string {
  return template.replace(/\{\{\s*vars\.([a-zA-Z0-9_]+)\s*\}\}/g, (_, key: string) => {
    if (!(key in vars)) {
      throw new Error(`Missing scenario variable: ${key}`);
    }
    return vars[key];
  });
}

function resolveTemplates<T>(value: T, vars: Record<string, string>): T {
  if (typeof value === "string") {
    return interpolateString(value, vars) as T;
  }
  if (Array.isArray(value)) {
    return value.map((entry) => resolveTemplates(entry, vars)) as T;
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [key, resolveTemplates(entry, vars)]),
    ) as T;
  }
  return value;
}

function readPath(target: unknown, path: string): unknown {
  if (path === "") {
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

function evaluateAssertion(output: unknown, assertion: StepAssertion): StepAssertionResult {
  const actual = readPath(output, assertion.path);
  let passed = false;
  switch (assertion.operator) {
    case "truthy":
      passed = Boolean(actual);
      break;
    case "equals":
      passed = Object.is(actual, assertion.value);
      break;
    case "includes":
      if (typeof actual === "string" && typeof assertion.value === "string") {
        passed = actual.includes(assertion.value);
      } else if (Array.isArray(actual)) {
        passed = actual.includes(assertion.value);
      }
      break;
    case "gte":
      passed = typeof actual === "number" && typeof assertion.value === "number" && actual >= assertion.value;
      break;
    case "minLength": {
      const length =
        typeof actual === "string" || Array.isArray(actual)
          ? actual.length
          : actual && typeof actual === "object" && "length" in (actual as Record<string, unknown>)
            ? Number((actual as { length: number }).length)
            : -1;
      passed = typeof assertion.value === "number" && length >= assertion.value;
      break;
    }
  }
  return {
    path: assertion.path,
    operator: assertion.operator,
    expected: assertion.value,
    actual,
    passed,
    message: assertion.message,
  };
}

function serializeCommand(step: ScenarioStep, resolvedArgs?: string[]): string | undefined {
  switch (step.kind) {
    case "cas_command":
      return `sydradb cas ${step.json === false ? "" : "--json "}${(resolvedArgs ?? step.args).join(" ")}`.trim();
    case "shell_command":
      return `sydradb ${(resolvedArgs ?? step.args).join(" ")}`;
    case "sydraql_query":
      return step.query;
    default:
      return undefined;
  }
}

async function executeStep(
  manifest: ScenarioManifest,
  step: ScenarioStep,
  sandbox: ScenarioSandbox,
  binaryPath: string,
): Promise<ScenarioStepResult> {
  const workspace = step.kind === "server_control" ? sandbox.workspaces[step.workspace] : "workspace" in step ? sandbox.workspaces[step.workspace] : undefined;
  if ("workspace" in step && !workspace) {
    throw new Error(`Unknown workspace ${step.workspace} in scenario ${manifest.id}`);
  }

  let output: unknown = undefined;
  let textOutput: string | undefined;
  let command: string | undefined;

  switch (step.kind) {
    case "cas_command": {
      const resolvedArgs = resolveTemplates(step.args, sandbox.vars);
      command = serializeCommand(step, resolvedArgs);
      if (step.json === false) {
        const result = await runBinary(workspace!, binaryPath, ["cas", ...resolvedArgs]);
        output = result;
        textOutput = result.combined;
      } else {
        output = await runCasJson(workspace!, binaryPath, resolvedArgs);
      }
      break;
    }
    case "shell_command": {
      const resolvedArgs = resolveTemplates(step.args, sandbox.vars);
      command = serializeCommand(step, resolvedArgs);
      const result = await runBinary(workspace!, binaryPath, resolvedArgs);
      output = result;
      textOutput = result.combined;
      break;
    }
    case "sydraql_query": {
      const resolvedQuery = resolveTemplates(step.query, sandbox.vars);
      command = serializeCommand(step);
      await startWorkspaceServer(workspace!, binaryPath);
      output = await postSydraqlQuery(workspace!, resolvedQuery);
      break;
    }
    case "query_range": {
      const resolvedPayload = resolveTemplates(step.payload, sandbox.vars);
      await startWorkspaceServer(workspace!, binaryPath);
      output = await postRangeQuery(workspace!, resolvedPayload);
      break;
    }
    case "metrics_snapshot": {
      await startWorkspaceServer(workspace!, binaryPath);
      output = await fetchMetricsCounters(workspace!, resolveTemplates(step.counters, sandbox.vars));
      break;
    }
    case "server_control": {
      if (step.action === "start") {
        await startWorkspaceServer(workspace!, binaryPath);
      } else if (step.action === "stop") {
        await stopWorkspaceServer(workspace!);
      } else {
        await restartWorkspaceServer(workspace!, binaryPath);
      }
      output = { action: step.action, workspace: workspace!.name, status: "ok" };
      break;
    }
  }

  const assertions = (step.assertions ?? []).map((assertion) => evaluateAssertion(output, assertion));
  const failedAssertion = assertions.find((assertion) => !assertion.passed);

  return {
    id: step.id,
    title: step.title,
    summary: step.summary,
    kind: step.kind,
    status: failedAssertion ? "failed" : "passed",
    command,
    output,
    textOutput,
    assertions,
  };
}

export async function runScenarioManifest(
  manifest: ScenarioManifest,
  sandbox: ScenarioSandbox,
  binaryPath: string,
  sessionId: string,
): Promise<ScenarioRunResult> {
  const startedAt = new Date().toISOString();
  const steps: ScenarioStepResult[] = [];
  let status: ScenarioRunResult["status"] = "passed";

  for (const step of manifest.steps) {
    try {
      const result = await executeStep(manifest, step, sandbox, binaryPath);
      steps.push(result);
      if (result.status === "failed") {
        status = "failed";
        break;
      }
    } catch (error) {
      steps.push({
        id: step.id,
        title: step.title,
        summary: step.summary,
        kind: step.kind,
        status: "failed",
        command: serializeCommand(step),
        textOutput: error instanceof Error ? error.message : String(error),
        assertions: [],
      });
      status = "failed";
      break;
    }
  }

  const finishedAt = new Date().toISOString();
  const result: ScenarioRunResult = {
    scenarioId: manifest.id,
    status,
    startedAt,
    finishedAt,
    sessionId,
    workspaceRoot: sandbox.rootDir,
    steps,
  };
  result.summaryEvidence = buildSummaryEvidence(result);
  return result;
}

