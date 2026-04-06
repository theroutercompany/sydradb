import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export interface DemoAppPaths {
  appRoot: string;
  scenariosDir: string;
  fixturesDir: string;
  uiRoot: string;
}

function hasDemoAssets(candidate: string): boolean {
  return (
    fs.existsSync(path.join(candidate, "scenarios")) &&
    fs.existsSync(path.join(candidate, "fixtures")) &&
    fs.existsSync(path.join(candidate, "ui"))
  );
}

export function resolveDemoRoot(startRef: string): string {
  const startDir = startRef.startsWith("file:")
    ? path.dirname(fileURLToPath(startRef))
    : startRef;

  const candidates: string[] = [];
  let current = path.resolve(startDir);
  for (let depth = 0; depth < 8; depth += 1) {
    candidates.push(current);
    const parent = path.dirname(current);
    if (parent === current) {
      break;
    }
    current = parent;
  }

  for (const candidate of candidates) {
    if (hasDemoAssets(candidate)) {
      return candidate;
    }
  }

  return candidates[0];
}

export function resolveDemoPaths(startRef: string): DemoAppPaths {
  const appRoot = resolveDemoRoot(startRef);
  return {
    appRoot,
    scenariosDir: path.join(appRoot, "scenarios"),
    fixturesDir: path.join(appRoot, "fixtures"),
    uiRoot: path.join(appRoot, "ui"),
  };
}

export function findRepoRoot(start = process.cwd()): string {
  let current = start;
  while (true) {
    if (fs.existsSync(path.join(current, "build.zig"))) {
      return current;
    }
    const parent = path.dirname(current);
    if (parent === current) {
      throw new Error(`Unable to locate repo root from ${start}`);
    }
    current = parent;
  }
}

export function resolveSydraBinary(repoRoot: string): string {
  return process.env.SYDRADB_BIN ?? path.join(repoRoot, "zig-out", "bin", "sydradb");
}
