import fs from "node:fs/promises";
import path from "node:path";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import net from "node:net";

export type CompilerMode = "compiled" | "legacy" | "shadow";

export interface WorkspaceRuntime {
  name: string;
  dir: string;
  dataDir: string;
  configPath: string;
  compilerMode: CompilerMode;
  port: number;
  baseUrl: string;
  server?: ChildProcessWithoutNullStreams;
}

export interface ScenarioSandbox {
  rootDir: string;
  workspaces: Record<string, WorkspaceRuntime>;
  vars: Record<string, string>;
}

export interface ProcessResult {
  code: number;
  stdout: string;
  stderr: string;
  combined: string;
}

export async function allocatePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        reject(new Error("Unable to allocate a local port"));
        return;
      }
      const { port } = address;
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(port);
      });
    });
  });
}

export async function createWorkspace(
  rootDir: string,
  name: string,
  compilerMode: CompilerMode = "compiled",
): Promise<WorkspaceRuntime> {
  const dir = path.join(rootDir, name);
  const dataDir = path.join(dir, "data");
  const configPath = path.join(dir, "sydradb.toml");
  const port = await allocatePort();

  await fs.mkdir(dataDir, { recursive: true });
  await fs.writeFile(
    configPath,
    [
      'data_dir = "./data"',
      `http_port = ${port}`,
      'fsync = "none"',
      "flush_interval_ms = 25",
      "memtable_max_bytes = 32768",
      "mem_limit_bytes = 268435456",
      'auth_token = ""',
      "enable_influx = false",
      "enable_prom = true",
      'cas_mode = "dual_write"',
      'metadata_read_mode = "primary"',
      `query_compiler_mode = "${compilerMode}"`,
      "retention_days = 0",
      "",
    ].join("\n"),
    "utf8",
  );

  return {
    name,
    dir,
    dataDir,
    configPath,
    compilerMode,
    port,
    baseUrl: `http://127.0.0.1:${port}`,
  };
}

export async function runBinary(
  workspace: WorkspaceRuntime,
  binaryPath: string,
  args: string[],
  options: { stdin?: string } = {},
): Promise<ProcessResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(binaryPath, args, {
      cwd: workspace.dir,
      env: process.env,
      stdio: "pipe",
    });

    let stdout = "";
    let stderr = "";

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      const result = {
        code: code ?? 1,
        stdout,
        stderr,
        combined: [stdout.trim(), stderr.trim()].filter(Boolean).join("\n"),
      };
      if ((code ?? 1) !== 0) {
        reject(new Error(`Command failed in ${workspace.name}: sydradb ${args.join(" ")}\n${result.combined}`));
        return;
      }
      resolve(result);
    });

    if (options.stdin) {
      child.stdin.write(options.stdin);
    }
    child.stdin.end();
  });
}

export async function waitForHttp(url: string, timeoutMs = 10_000): Promise<void> {
  const startedAt = Date.now();
  let lastError: unknown = null;
  while (Date.now() - startedAt < timeoutMs) {
    try {
      const response = await fetch(url);
      if (response.ok) {
        return;
      }
      lastError = new Error(`Unexpected status ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw lastError instanceof Error ? lastError : new Error(`Timed out waiting for ${url}`);
}

export async function startWorkspaceServer(workspace: WorkspaceRuntime, binaryPath: string): Promise<void> {
  if (workspace.server && workspace.server.exitCode === null) {
    return;
  }

  const child = spawn(binaryPath, [], {
    cwd: workspace.dir,
    env: process.env,
    stdio: "pipe",
  });
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  workspace.server = child;
  await waitForHttp(`${workspace.baseUrl}/status`);
}

export async function stopWorkspaceServer(workspace: WorkspaceRuntime): Promise<void> {
  if (!workspace.server || workspace.server.exitCode !== null) {
    workspace.server = undefined;
    return;
  }

  const child = workspace.server;
  await new Promise<void>((resolve) => {
    child.once("close", () => resolve());
    child.kill("SIGTERM");
    setTimeout(() => {
      if (child.exitCode === null) {
        child.kill("SIGKILL");
      }
    }, 2_000).unref();
  });
  workspace.server = undefined;
}

export async function restartWorkspaceServer(workspace: WorkspaceRuntime, binaryPath: string): Promise<void> {
  await stopWorkspaceServer(workspace);
  await startWorkspaceServer(workspace, binaryPath);
}

export async function seedWorkspaceFromFixtures(
  workspace: WorkspaceRuntime,
  binaryPath: string,
  fixtureFiles: string[],
): Promise<void> {
  await startWorkspaceServer(workspace, binaryPath);
  const payloadChunks = await Promise.all(fixtureFiles.map((filePath) => fs.readFile(filePath, "utf8")));
  const payload = payloadChunks.map((chunk) => chunk.trim()).filter(Boolean).join("\n") + "\n";
  const response = await fetch(`${workspace.baseUrl}/api/v1/ingest`, {
    method: "POST",
    body: payload,
    headers: { "Content-Type": "application/x-ndjson" },
  });
  if (!response.ok) {
    throw new Error(`Failed to seed ${workspace.name}: ${response.status} ${await response.text()}`);
  }
  await new Promise((resolve) => setTimeout(resolve, 150));
  await stopWorkspaceServer(workspace);
}

export async function postSydraqlQuery(workspace: WorkspaceRuntime, query: string): Promise<unknown> {
  const response = await fetch(`${workspace.baseUrl}/api/v1/sydraql`, {
    method: "POST",
    body: query,
    headers: { "Content-Type": "text/plain" },
  });
  if (!response.ok) {
    throw new Error(`sydraQL query failed for ${workspace.name}: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as unknown;
}

export async function postRangeQuery(
  workspace: WorkspaceRuntime,
  payload: Record<string, unknown>,
): Promise<unknown> {
  const response = await fetch(`${workspace.baseUrl}/api/v1/query/range`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    throw new Error(`Range query failed for ${workspace.name}: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as unknown;
}

export async function fetchMetricsCounters(
  workspace: WorkspaceRuntime,
  counters: string[],
): Promise<{ counters: Record<string, number>; raw: string }> {
  const response = await fetch(`${workspace.baseUrl}/metrics`);
  if (!response.ok) {
    throw new Error(`Metrics fetch failed for ${workspace.name}: ${response.status} ${await response.text()}`);
  }
  const raw = await response.text();
  const values: Record<string, number> = {};
  for (const counter of counters) {
    const pattern = new RegExp(`^${counter}\\s+([0-9]+(?:\\.[0-9]+)?)$`, "m");
    const match = raw.match(pattern);
    values[counter] = match ? Number(match[1]) : Number.NaN;
  }
  return { counters: values, raw };
}

export async function runCasJson(
  workspace: WorkspaceRuntime,
  binaryPath: string,
  args: string[],
): Promise<unknown> {
  const result = await runBinary(workspace, binaryPath, ["cas", "--json", ...args]);
  return JSON.parse(result.stdout) as unknown;
}

export async function warmWorkspace(workspace: WorkspaceRuntime, binaryPath: string): Promise<void> {
  await startWorkspaceServer(workspace, binaryPath);
  await stopWorkspaceServer(workspace);
}

export function createSandbox(rootDir: string, workspaces: Record<string, WorkspaceRuntime>): ScenarioSandbox {
  const vars: Record<string, string> = { run_id: randomUUID() };
  for (const [name, workspace] of Object.entries(workspaces)) {
    vars[`${name.replaceAll("-", "_")}_dir`] = workspace.dir;
    vars[`${name.replaceAll("-", "_")}_data_dir`] = workspace.dataDir;
  }
  return { rootDir, workspaces, vars };
}

export async function cleanupSandbox(sandbox: ScenarioSandbox, preserveArtifacts = true): Promise<void> {
  await Promise.all(Object.values(sandbox.workspaces).map((workspace) => stopWorkspaceServer(workspace)));
  if (!preserveArtifacts) {
    await fs.rm(sandbox.rootDir, { recursive: true, force: true });
  }
}
