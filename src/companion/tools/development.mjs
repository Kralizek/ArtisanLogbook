import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const data = path.join(root, ".artifacts", "development");
const [command, confirmation] = process.argv.slice(2);
if (command === "import-fixture") {
  const fixture = path.resolve(
    root,
    "../addon/tests/fixtures/legacy/v1-outcome1.lua",
  );
  const result = spawnSync(
    "dotnet",
    [
      "run",
      "--project",
      path.join(root, "src/Cli/Cli.csproj"),
      "-p:CompanionWebDevelopment=true",
      "--",
      "import",
      fixture,
    ],
    {
      cwd: root,
      stdio: "inherit",
      env: { ...process.env, ARTISAN_LOGBOOK_DATA_DIRECTORY: data },
    },
  );
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} else if (command === "reset") {
  assert.equal(
    confirmation,
    "--confirm",
    "Stop Aspire, then explicitly confirm: node tools/development.mjs reset --confirm",
  );
  if (existsSync(path.join(data, "history.duckdb"))) {
    const probe = spawnSync(
      "dotnet",
      [
        "run",
        "--project",
        path.join(root, "src/Cli/Cli.csproj"),
        "-p:CompanionWebDevelopment=true",
        "--",
        "status",
      ],
      {
        cwd: root,
        stdio: "inherit",
        env: { ...process.env, ARTISAN_LOGBOOK_DATA_DIRECTORY: data },
      },
    );
    if (probe.error) throw probe.error;
    assert.equal(
      probe.status,
      0,
      "Reset refused: the development database is busy or cannot be opened. Stop Aspire first.",
    );
  }
  // This one repository-owned directory is the only reset target.
  await rm(data, { recursive: true, force: true });
  console.log(`Reset isolated development data: ${data}`);
} else {
  throw new Error(
    "Usage: node tools/development.mjs import-fixture | reset --confirm (stop Aspire first)",
  );
}
