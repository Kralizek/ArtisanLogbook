import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { chmod, copyFile, mkdtemp, readdir, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { smokeBrowser } from "../web/scripts/smoke-browser.mjs";

const [executable, fixture] = process.argv.slice(2);
assert(
  executable && fixture,
  "Usage: node tools/smoke-publish.mjs <published executable> <fixture>",
);
const directory = await mkdtemp(path.join(tmpdir(), "artisan-web-publish-"));
const binary = path.join(directory, path.basename(executable));
await copyFile(path.resolve(executable), binary);
await chmod(binary, 0o755);
assert.deepEqual(await readdir(directory), [path.basename(binary)]);
const environment = {
  ...process.env,
  ARTISAN_LOGBOOK_DATA_DIRECTORY: path.join(directory, "data"),
};
// The application receives no Node/npm/Aspire PATH or source-tree working directory.
environment.PATH = "";

async function runHost(populated) {
  const listener = createServer();
  listener.listen(0, "127.0.0.1");
  await once(listener, "listening");
  const port = listener.address().port;
  await new Promise((resolve) => listener.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const child = spawn(
    binary,
    ["serve", "--monitoring", "false", "--require-port", "--port", `${port}`],
    {
      cwd: directory,
      env: environment,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  let logs = "";
  child.stdout.on("data", (data) => {
    logs += data;
  });
  child.stderr.on("data", (data) => {
    logs += data;
  });
  const exited = once(child, "exit");
  try {
    let healthy = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      if (child.exitCode !== null)
        throw new Error(`Companion exited early:\n${logs}`);
      try {
        healthy = (await fetch(`${base}/api/v1/health`)).ok;
      } catch (error) {
        if (!(error instanceof TypeError)) throw error;
      }
      if (healthy) break;
      await delay(250);
    }
    assert(healthy, `Companion did not become healthy:\n${logs}`);
    const root = await fetch(base);
    assert.equal(root.status, 200);
    assert.match(root.headers.get("content-type"), /^text\/html/);
    assert.equal(root.headers.get("cache-control"), "no-store");
    const html = await root.text();
    const assets = [
      ...html.matchAll(/(?:src|href)="(\/assets\/[^"]+\.(js|css))"/g),
    ];
    assert(
      assets.some((asset) => asset[2] === "js"),
      html,
    );
    assert(
      assets.some((asset) => asset[2] === "css"),
      html,
    );
    for (const [, asset, extension] of assets) {
      const response = await fetch(`${base}${asset}`);
      assert.equal(response.status, 200, asset);
      assert.match(
        response.headers.get("content-type"),
        extension === "js" ? /^(text|application)\/javascript/ : /^text\/css/,
      );
      assert((await response.text()).length > 0);
    }
    assert.equal(await (await fetch(`${base}/history`)).text(), html);
    for (const missing of [
      "/assets/missing.js",
      "/api/v1/missing",
      "/openapi/missing.yaml",
    ]) {
      const response = await fetch(`${base}${missing}`);
      assert.equal(response.status, 404);
      assert.match(
        response.headers.get("content-type"),
        /^application\/problem\+json/,
      );
    }
    assert.equal((await fetch(`${base}/openapi/v1.yaml`)).status, 200);
    const status = await (await fetch(`${base}/api/v1/status`)).json();
    assert.equal(status.state, "Running");
    assert.equal(status.history.craftCount > 0, populated);
    const query = await fetch(`${base}/graphql`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Artisan-Logbook-Client": "web",
      },
      body: JSON.stringify({
        query:
          "{ crafts(first: 20) { nodes { id recordedAt character { id name } recipe { id name } concentrationSpent } pageInfo { hasNextPage endCursor } } }",
      }),
    });
    assert.equal(query.status, 200);
    const graph = await query.json();
    assert.equal(graph.errors, undefined, JSON.stringify(graph.errors));
    assert.equal(graph.data.crafts.nodes.length > 0, populated);
    assert.equal((await fetch(`${base}/graphql`)).status, 404);
    assert.equal(
      (await fetch(base, { headers: { Origin: "https://attacker.example" } }))
        .status,
      403,
    );
    await smokeBrowser(
      base,
      populated ? "production-fixture" : "production-empty",
    );
    console.log(
      `Single-executable smoke passed (${populated ? "fixture history" : "empty history"}).`,
    );
  } finally {
    if (child.exitCode === null) child.kill("SIGINT");
    const [code, signal] = await exited;
    if (process.platform !== "win32") {
      assert.equal(
        code,
        0,
        `Host did not stop gracefully (${signal}):\n${logs}`,
      );
    }
  }
}

try {
  await runHost(false);
  const imported = spawnSync(binary, ["import", path.resolve(fixture)], {
    cwd: directory,
    env: environment,
    encoding: "utf8",
  });
  assert.equal(imported.status, 0, `${imported.stdout}\n${imported.stderr}`);
  await runHost(true);
} finally {
  await rm(directory, { recursive: true, force: true });
}
