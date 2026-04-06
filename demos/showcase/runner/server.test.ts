import { afterEach, describe, expect, test } from "vitest";

import { startShowcaseServer } from "./server.js";

describe("startShowcaseServer", () => {
  let activeServer: Awaited<ReturnType<typeof startShowcaseServer>> | null = null;

  afterEach(async () => {
    if (activeServer) {
      await activeServer.close();
      activeServer = null;
    }
  });

  test("rejects cleanly when the port is already in use", async () => {
    activeServer = await startShowcaseServer(4297, "127.0.0.1");

    await expect(startShowcaseServer(4297, "127.0.0.1")).rejects.toThrow(/EADDRINUSE/);
  });
});
