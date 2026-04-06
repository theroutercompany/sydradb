import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const runnerPort = Number(process.env.TRADING_SHOWCASE_RUNNER_PORT ?? 4277);
const uiRoot = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  root: uiRoot,
  plugins: [react()],
  build: {
    outDir: path.join(uiRoot, "dist"),
    emptyOutDir: true,
  },
  server: {
    host: "127.0.0.1",
    port: 4273,
    proxy: {
      "/api/demo": {
        target: `http://127.0.0.1:${runnerPort}`,
        changeOrigin: true,
      },
    },
  },
  preview: {
    host: "127.0.0.1",
    port: 4273,
  },
});
