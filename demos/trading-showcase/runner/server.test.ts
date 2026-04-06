import { afterEach, describe, expect, test } from "vitest";

import { startTradingShowcaseServer } from "./server.js";

describe("startTradingShowcaseServer", () => {
  let activeServer: Awaited<ReturnType<typeof startTradingShowcaseServer>> | null = null;

  afterEach(async () => {
    if (activeServer) {
      await activeServer.close();
      activeServer = null;
    }
  });

  test("rejects cleanly when the port is already in use", async () => {
    activeServer = await startTradingShowcaseServer(4397, "127.0.0.1");
    await expect(startTradingShowcaseServer(4397, "127.0.0.1")).rejects.toThrow(/EADDRINUSE/);
  });
});
