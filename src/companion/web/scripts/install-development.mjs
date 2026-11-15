import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
rmSync(
  new URL("../node_modules/.companion-production-restore", import.meta.url),
  {
    force: true,
  },
);
const result = spawnSync(
  process.platform === "win32" ? "npm.cmd" : "npm",
  ["install", "--no-save", "--include=dev", "--no-audit", "--no-fund"],
  { cwd: root, stdio: "inherit", shell: process.platform === "win32" },
);
if (result.error) throw result.error;
if (result.status !== 0) {
  throw new Error(
    `Development npm install failed (exit ${result.status ?? "unknown"}).`,
  );
}
