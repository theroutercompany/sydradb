import express from "express";
import fs from "node:fs";
import path from "node:path";

import { TradingShowcaseSessionManager } from "./sessionManager.js";
import { uiRoot } from "./paths.js";

const runnerPort = Number(process.env.TRADING_SHOWCASE_RUNNER_PORT ?? 4277);
const runnerHost = process.env.TRADING_SHOWCASE_HOST ?? "127.0.0.1";

export function createTradingShowcaseApp(manager = new TradingShowcaseSessionManager()) {
  const app = express();
  app.use(express.json({ limit: "2mb" }));

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
    const message = error instanceof Error ? error.message : "Unknown trading showcase error";
    res.status(500).json({ ok: false, error: message });
  });

  return { app, manager };
}

export async function startTradingShowcaseServer(port = runnerPort, host = runnerHost) {
  const { app, manager } = createTradingShowcaseApp();
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
  startTradingShowcaseServer().then(({ port, host }) => {
    console.log(`Sydra trading showcase runner listening on http://${host}:${port}`);
  }).catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
