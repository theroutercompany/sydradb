import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";

import type { DemoAppPaths } from "./paths.js";
import { findRepoRoot, resolveSydraBinary } from "./paths.js";
import type { DemoStateResponse, ScenarioManifest, ScenarioRunResult } from "./contracts.js";
import { buildScenarioAvailability, buildScenarioSummaries } from "./scenarioRegistry.js";
import { cleanupSandbox, type ScenarioSandbox } from "./runtime.js";
import { runScenarioManifest, type SummaryEvidenceBuilder } from "./scenarioRunner.js";

export type SeedRoutine = (rootDir: string, binaryPath: string) => Promise<ScenarioSandbox>;
export type CleanupRoutine = (sandbox: ScenarioSandbox, preserveArtifacts?: boolean) => Promise<void>;

interface SessionSnapshot {
  id: string;
  rootDir: string;
  repoRoot: string;
  binaryPath: string;
  capabilities: Record<string, boolean>;
  manifests: ScenarioManifest[];
}

export interface DemoSessionManagerOptions {
  appId: string;
  appPaths: DemoAppPaths;
  loadManifests: () => Promise<ScenarioManifest[]>;
  detectCapabilities: (sessionRoot: string, binaryPath: string) => Promise<Record<string, boolean>>;
  seedRoutines: Record<string, SeedRoutine>;
  cleanupRoutines?: Record<string, CleanupRoutine>;
  summaryEvidenceBuilder?: SummaryEvidenceBuilder;
}

export class DemoSessionManager {
  private session: SessionSnapshot | null = null;
  private operationChain: Promise<void> = Promise.resolve();

  constructor(private readonly options: DemoSessionManagerOptions) {}

  async reset(): Promise<DemoStateResponse> {
    return this.withLock(async () => this.resetUnlocked());
  }

  async getState(): Promise<DemoStateResponse> {
    return this.withLock(async () => {
      if (!this.session) {
        return this.resetUnlocked();
      }
      return this.toState();
    });
  }

  async runScenario(scenarioId: string): Promise<ScenarioRunResult> {
    return this.withLock(async () => {
      const state = this.session ? this.toState() : await this.resetUnlocked();
      const session = this.session!;
      const manifest = session.manifests.find((entry) => entry.id === scenarioId);
      if (!manifest) {
        throw new Error(`Unknown scenario ${scenarioId}`);
      }

      const availability = buildScenarioAvailability([manifest], session.capabilities)[0];
      if (!availability.available) {
        return {
          scenarioId,
          status: "blocked",
          startedAt: new Date().toISOString(),
          finishedAt: new Date().toISOString(),
          sessionId: state.sessionId,
          workspaceRoot: session.rootDir,
          steps: [],
        };
      }

      const scenarioRoot = path.join(session.rootDir, "runs", `${scenarioId}-${Date.now()}`);
      await fsp.mkdir(scenarioRoot, { recursive: true });
      const seedRoutine = this.options.seedRoutines[manifest.seedRoutine];
      const cleanupRoutine = this.options.cleanupRoutines?.[manifest.cleanupRoutine] ?? cleanupSandbox;
      if (!seedRoutine) {
        throw new Error(`Unknown seed routine ${manifest.seedRoutine}`);
      }

      const sandbox = await seedRoutine(scenarioRoot, session.binaryPath);
      try {
        return await runScenarioManifest(
          manifest,
          sandbox,
          session.binaryPath,
          session.id,
          this.options.summaryEvidenceBuilder,
        );
      } finally {
        await cleanupRoutine(sandbox, true);
      }
    });
  }

  async close(): Promise<void> {
    await this.withLock(async () => {
      await this.closeUnlocked();
    });
  }

  private async withLock<T>(operation: () => Promise<T>): Promise<T> {
    const run = this.operationChain.then(operation, operation);
    this.operationChain = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  private async resetUnlocked(): Promise<DemoStateResponse> {
    await this.closeUnlocked();
    const repoRoot = process.env.SYDRADB_BIN ? process.cwd() : findRepoRoot(this.options.appPaths.appRoot);
    const binaryPath = resolveSydraBinary(repoRoot);
    const sessionId = randomUUID();
    const sessionRoot = path.join(os.tmpdir(), `sydra-${this.options.appId}-${sessionId}`);
    await fsp.mkdir(sessionRoot, { recursive: true });

    const manifests = await this.options.loadManifests();
    const capabilities = fs.existsSync(binaryPath)
      ? await this.options.detectCapabilities(sessionRoot, binaryPath)
      : { "binary.present": false };

    this.session = {
      id: sessionId,
      rootDir: sessionRoot,
      repoRoot,
      binaryPath,
      capabilities,
      manifests,
    };
    return this.toState();
  }

  private async closeUnlocked(): Promise<void> {
    if (!this.session) {
      return;
    }
    await fsp.rm(this.session.rootDir, { recursive: true, force: true });
    this.session = null;
  }

  private toState(): DemoStateResponse {
    if (!this.session) {
      throw new Error("Demo session is not initialized");
    }

    return {
      sessionId: this.session.id,
      sessionRoot: this.session.rootDir,
      repoRoot: this.session.repoRoot,
      binaryPath: this.session.binaryPath,
      capabilities: this.session.capabilities,
      scenarios: buildScenarioSummaries(this.session.manifests, this.session.capabilities),
    };
  }
}
