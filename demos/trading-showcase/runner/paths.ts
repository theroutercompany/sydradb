import path from "node:path";
import { fileURLToPath } from "node:url";

import { findRepoRoot, resolveDemoPaths, resolveDemoRoot, resolveSydraBinary } from "../../shared/runtime/paths.js";

const runnerEntry = fileURLToPath(import.meta.url);
const runnerDir = path.dirname(runnerEntry);

export function resolveTradingShowcaseRoot(start = runnerDir): string {
  return resolveDemoRoot(start);
}

const tradingPaths = resolveDemoPaths(import.meta.url);

export const tradingShowcaseRoot = tradingPaths.appRoot;
export const scenariosDir = tradingPaths.scenariosDir;
export const fixturesDir = tradingPaths.fixturesDir;
export const uiRoot = tradingPaths.uiRoot;

export { findRepoRoot, resolveSydraBinary };
