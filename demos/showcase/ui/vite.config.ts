import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const runnerPort = Number(process.env.SHOWCASE_RUNNER_PORT ?? 4177);

export default defineConfig({
  plugins: [react()],
  server: {
    host: "127.0.0.1",
    port: 4173,
    proxy: {
      "/api/demo": {
        target: `http://127.0.0.1:${runnerPort}`,
        changeOrigin: true,
      },
    },
  },
  preview: {
    host: "127.0.0.1",
    port: 4173,
  },
});
