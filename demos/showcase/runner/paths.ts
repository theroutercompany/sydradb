import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const runnerEntry = fileURLToPath(import.meta.url);
const runnerDir = path.dirname(runnerEntry);

function hasShowcaseAssets(candidate: string): boolean {
  return (
    fs.existsSync(path.join(candidate, "scenarios")) &&
    fs.existsSync(path.join(candidate, "fixtures")) &&
    fs.existsSync(path.join(candidate, "ui"))
  );
}

export function resolveShowcaseRoot(start = runnerDir): string {
  const candidates = [
    path.resolve(start, ".."),
    path.resolve(start, "../../.."),
  ];

  for (const candidate of candidates) {
    if (hasShowcaseAssets(candidate)) {
      return candidate;
    }
  }

  return path.resolve(start, "..");
}

export const showcaseRoot = resolveShowcaseRoot();
export const scenariosDir = path.join(showcaseRoot, "scenarios");
export const fixturesDir = path.join(showcaseRoot, "fixtures");
export const uiRoot = path.join(showcaseRoot, "ui");

export function findRepoRoot(start = showcaseRoot): string {
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
