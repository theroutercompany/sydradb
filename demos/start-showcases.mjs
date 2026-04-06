import { startShowcaseServer } from "./showcase/dist/runner/showcase/runner/server.js";
import { startTradingShowcaseServer } from "./trading-showcase/dist/runner/trading-showcase/runner/server.js";

async function main() {
  const showcase = await startShowcaseServer();
  try {
    const trading = await startTradingShowcaseServer();
    let closing = false;

    const closeAll = async (exitCode = 0) => {
      if (closing) return;
      closing = true;
      const results = await Promise.allSettled([trading.close(), showcase.close()]);
      const rejected = results.find((result) => result.status === "rejected");
      if (rejected?.status === "rejected") {
        console.error(rejected.reason);
        process.exitCode = 1;
        return;
      }
      process.exitCode = exitCode;
    };

    for (const signal of ["SIGINT", "SIGTERM"]) {
      process.once(signal, () => {
        void closeAll(0);
      });
    }

    process.once("uncaughtException", (error) => {
      console.error(error);
      void closeAll(1);
    });

    process.once("unhandledRejection", (error) => {
      console.error(error);
      void closeAll(1);
    });

    console.log(
      `Unified Sydra showcase container listening on http://${showcase.host}:${showcase.port} and http://${trading.host}:${trading.port}`,
    );
  } catch (error) {
    await showcase.close().catch(() => {});
    throw error;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
