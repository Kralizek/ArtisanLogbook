import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { smokeBrowser } from "./smoke-browser.mjs";

const companionRoot = fileURLToPath(new URL("../../", import.meta.url));
const directory = await mkdtemp(
  path.join(tmpdir(), "artisan-web-development-"),
);
async function port() {
  const listener = createServer();
  listener.listen(0, "127.0.0.1");
  await once(listener, "listening");
  const value = listener.address().port;
  await new Promise((resolve) => listener.close(resolve));
  return value;
}
const [backendPort, webPort] = await Promise.all([port(), port()]);
const environment = {
  ...process.env,
  CompanionWebDevelopment: "true",
  ARTISAN_LOGBOOK_DATA_DIRECTORY: directory,
  Development__DataDirectory: directory,
  Development__CompanionPort: `${backendPort}`,
  Development__WebPort: `${webPort}`,
  Development__InstallFrontend: "false",
  ASPIRE_CLI_TELEMETRY_OPTOUT: "true",
};
const imported = spawnSync(
  "dotnet",
  [
    "run",
    "--project",
    "src/Cli/Cli.csproj",
    "--",
    "import",
    "../addon/tests/fixtures/legacy/v1-outcome1.lua",
  ],
  { cwd: companionRoot, env: environment, encoding: "utf8" },
);
assert.equal(imported.status, 0, `${imported.stdout}\n${imported.stderr}`);

const child = spawn(
  "aspire",
  ["run", "--apphost", "tools/AppHost/AppHost.csproj", "--non-interactive"],
  {
    cwd: companionRoot,
    env: environment,
    stdio: ["ignore", "pipe", "pipe"],
  },
);
const exited = once(child, "exit");
let logs = "";
child.stdout.on("data", (value) => {
  logs += value;
});
child.stderr.on("data", (value) => {
  logs += value;
});
const base = `http://127.0.0.1:${webPort}`;
try {
  let ready = false;
  for (let attempt = 0; attempt < 1200; attempt++) {
    if (child.exitCode !== null)
      throw new Error(`Aspire exited early:\n${logs}`);
    try {
      const response = await fetch(`${base}/api/v1/health`);
      ready = response.ok;
    } catch (error) {
      if (!(error instanceof TypeError)) throw error;
    }
    if (ready) break;
    await delay(500);
  }
  assert(ready, `Aspire/Vite did not become healthy:\n${logs}`);
  const status = await (
    await fetch(`${base}/api/v1/status`, {
      headers: {
        "X-Artisan-Logbook-Client": "web",
        Origin: base,
        "Sec-Fetch-Site": "same-origin",
      },
    })
  ).json();
  assert(status.history.craftCount > 0);
  assert.equal(
    (
      await fetch(`${base}/api/v1/health`, {
        headers: { Origin: "http://attacker.example" },
      })
    ).status,
    403,
  );
  assert.equal(
    (
      await fetch(`${base}/graphql`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Artisan-Logbook-Client": "web",
          Origin: "http://attacker.example",
          "Sec-Fetch-Site": "cross-site",
        },
        body: JSON.stringify({ query: "{ crafts { nodes { id } } }" }),
      })
    ).status,
    403,
  );
  await smokeBrowser(base, "development", true);
  console.log(
    "Aspire isolated fixture, health startup, REST/GraphQL proxy security and HMR passed.",
  );
} finally {
  if (child.exitCode === null) {
    if (process.platform === "win32") {
      const stopped = spawnSync(
        "taskkill",
        ["/PID", `${child.pid}`, "/T", "/F"],
        { encoding: "utf8" },
      );
      assert.equal(stopped.status, 0, `${stopped.stdout}\n${stopped.stderr}`);
    } else {
      child.kill("SIGINT");
    }
  }
  await exited;
  await rm(directory, { recursive: true, force: true });
}
