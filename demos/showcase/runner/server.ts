import express from "express";
import path from "node:path";
import fs from "node:fs";

import { ShowcaseSessionManager } from "./sessionManager.js";
import { uiRoot } from "./paths.js";

const runnerPort = Number(process.env.SHOWCASE_RUNNER_PORT ?? 4177);
const runnerHost = process.env.SHOWCASE_HOST ?? "127.0.0.1";

export function createShowcaseApp(manager = new ShowcaseSessionManager()) {
  const app = express();
  app.use(express.json({ limit: "1mb" }));

  app.get("/api/demo/health", (_req, res) => {
    res.json({ ok: true });
  });

  app.get("/api/demo/state", async (_req, res, next) => {
    try {
      res.json(await manager.getState());
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/demo/session/reset", async (_req, res, next) => {
    try {
      res.json(await manager.reset());
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/demo/scenarios/:scenarioId/run", async (req, res, next) => {
    try {
      res.json(await manager.runScenario(req.params.scenarioId));
    } catch (error) {
      next(error);
    }
  });

  const distDir = path.join(uiRoot, "dist");
  if (fs.existsSync(distDir)) {
    app.use(express.static(distDir));
    app.get("*", (req, res, next) => {
      if (req.path.startsWith("/api/demo")) {
        next();
        return;
      }
      res.sendFile(path.join(distDir, "index.html"));
    });
  }

  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    const message = error instanceof Error ? error.message : "Unknown showcase error";
    res.status(500).json({ ok: false, error: message });
  });

  return { app, manager };
}

export async function startShowcaseServer(port = runnerPort, host = runnerHost) {
  const { app, manager } = createShowcaseApp();
  const server = await new Promise<import("node:http").Server>((resolve, reject) => {
    const httpServer = app.listen(port, host);
    const onError = (error: Error) => {
      httpServer.off("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      httpServer.off("error", onError);
      resolve(httpServer);
    };
    httpServer.once("error", onError);
    httpServer.once("listening", onListening);
  }).catch(async (error) => {
    await manager.close().catch(() => {});
    throw error;
  });
  return {
    port,
    host,
    manager,
    close: async () => {
      await manager.close();
      await new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error) {
            reject(error);
            return;
          }
          resolve();
        });
      });
    },
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  startShowcaseServer().then(({ port, host }) => {
    console.log(`Sydra showcase runner listening on http://${host}:${port}`);
  }).catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
