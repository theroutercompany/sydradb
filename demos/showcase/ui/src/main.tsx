import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import App from "./App.js";
import "./styles.css";

function renderFatal(error: unknown) {
  const message = error instanceof Error ? `${error.name}: ${error.message}\n\n${error.stack ?? ""}` : String(error);
  const root = document.getElementById("root");
  if (!root) {
    document.body.innerHTML = `<pre style="padding:24px;color:#8b0000;white-space:pre-wrap;font:14px/1.5 monospace;">${message}</pre>`;
    return;
  }
  root.innerHTML = `<pre style="padding:24px;color:#8b0000;white-space:pre-wrap;font:14px/1.5 monospace;">${message}</pre>`;
}

window.addEventListener("error", (event) => {
  renderFatal(event.error ?? event.message);
});

window.addEventListener("unhandledrejection", (event) => {
  renderFatal(event.reason);
});

try {
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
} catch (error) {
  renderFatal(error);
}
