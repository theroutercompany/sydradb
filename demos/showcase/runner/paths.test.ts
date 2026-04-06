import { mkdtemp, mkdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { afterEach, describe, expect, test } from "vitest";

import { resolveShowcaseRoot } from "./paths.js";

const tempDirs: string[] = [];

async function createTempRoot() {
  const dir = await mkdtemp(path.join(os.tmpdir(), "sydra-showcase-paths-"));
  tempDirs.push(dir);
  return dir;
}

async function createShowcaseAssets(root: string) {
  await mkdir(path.join(root, "scenarios"), { recursive: true });
  await mkdir(path.join(root, "fixtures"), { recursive: true });
  await mkdir(path.join(root, "ui", "dist"), { recursive: true });
}

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

describe("resolveShowcaseRoot", () => {
  test("resolves the source workspace from the runner directory", async () => {
    const tempRoot = await createTempRoot();
    const showcaseRoot = path.join(tempRoot, "showcase");
    await createShowcaseAssets(showcaseRoot);
    const runnerRoot = path.join(showcaseRoot, "runner");
    await mkdir(runnerRoot, { recursive: true });

    expect(resolveShowcaseRoot(runnerRoot)).toBe(showcaseRoot);
  });

  test("resolves the source workspace from the built runner directory", async () => {
    const tempRoot = await createTempRoot();
    const showcaseRoot = path.join(tempRoot, "showcase");
    await createShowcaseAssets(showcaseRoot);
    const builtRunnerDir = path.join(showcaseRoot, "dist", "runner", "runner");
    await mkdir(builtRunnerDir, { recursive: true });

    expect(resolveShowcaseRoot(builtRunnerDir)).toBe(showcaseRoot);
  });

  test("prefers colocated assets when the dist layout is self-contained", async () => {
    const tempRoot = await createTempRoot();
    const distRoot = path.join(tempRoot, "dist", "runner");
    await createShowcaseAssets(distRoot);
    const builtRunnerDir = path.join(distRoot, "runner");
    await mkdir(builtRunnerDir, { recursive: true });

    expect(resolveShowcaseRoot(builtRunnerDir)).toBe(distRoot);
  });
});
