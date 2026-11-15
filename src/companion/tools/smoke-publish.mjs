import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { chmod, copyFile, mkdtemp, readdir, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { smokeBrowser } from "../web/scripts/smoke-browser.mjs";

const [executable, fixture, ...options] = process.argv.slice(2);
assert(
  executable &&
    fixture &&
    options.every((option) => option === "--skip-browser"),
  "Usage: node tools/smoke-publish.mjs <published executable> <fixture> [--skip-browser]",
);
const directory = await mkdtemp(path.join(tmpdir(), "artisan-web-publish-"));
const binary = path.join(directory, path.basename(executable));
const environment = {
  ...process.env,
  ARTISAN_LOGBOOK_DATA_DIRECTORY: path.join(directory, "data"),
  PATH: "",
};

try {
  await copyFile(path.resolve(executable), binary);
  await chmod(binary, 0o755);
  assert.deepEqual(await readdir(directory), [path.basename(binary)]);
  const imported = spawnSync(binary, ["import", path.resolve(fixture)], {
    cwd: directory,
    env: environment,
    encoding: "utf8",
  });
  if (imported.error) throw imported.error;
  assert.equal(imported.status, 0, `${imported.stdout}\n${imported.stderr}`);

  const listener = createServer();
  listener.listen(0, "127.0.0.1");
  await once(listener, "listening");
  const port = listener.address().port;
  await new Promise((resolve) => listener.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  let child = spawn(
    binary,
    ["serve", "--monitoring", "false", "--require-port", "--port", `${port}`],
    { cwd: directory, env: environment, stdio: ["ignore", "pipe", "pipe"] },
  );
  let logs = "";
  const captureLogs = (process) => {
    process.stdout.on("data", (data) => {
      logs += data;
    });
    process.stderr.on("data", (data) => {
      logs += data;
    });
  };
  captureLogs(child);
  let exited = once(child, "exit");
  const waitUntilHealthy = async () => {
    let healthy = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      if (child.exitCode !== null)
        throw new Error(`Companion exited early:\n${logs}`);
      try {
        healthy = (await fetch(`${base}/api/v1/health`)).ok;
      } catch (error) {
        if (!(error instanceof TypeError)) throw error;
      }
      if (healthy) return;
      await delay(250);
    }
    assert(healthy, `Companion did not become healthy:\n${logs}`);
  };
  const stateRequest = (route, method, body) =>
    fetch(`${base}${route}`, {
      method,
      headers: {
        "Content-Type": "application/json",
        "X-Artisan-Logbook-Client": "publish-smoke",
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  try {
    await waitUntilHealthy();
    const root = await fetch(base);
    assert.equal(root.status, 200);
    assert.match(root.headers.get("content-type"), /^text\/html/);
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
    const openapi = await fetch(`${base}/openapi/v1.yaml`);
    assert.equal(openapi.status, 200);
    assert.match(await openapi.text(), /openapi:/i);
    const status = await (await fetch(`${base}/api/v1/status`)).json();
    assert.equal(status.state, "Running");
    assert(status.history.craftCount > 0);
    const query = await fetch(`${base}/graphql`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Artisan-Logbook-Client": "web",
      },
      body: JSON.stringify({ query: "{ crafts { nodes { id } } }" }),
    });
    assert.equal(query.status, 200);
    const graph = await query.json();
    assert.equal(graph.errors, undefined, JSON.stringify(graph.errors));
    assert(graph.data.crafts.nodes.length > 0);

    const context = { project: 18, progressionTrack: "Hardcore" };
    const preferenceRoute =
      "/api/v1/entity-preferences/Item/987654321";
    for (const [suffix, property] of [
      ["/pin", "pinned"],
      ["/hidden", "hidden"],
    ]) {
      const mutation = await stateRequest(
        `${preferenceRoute}${suffix}`,
        "PUT",
        { context, [property]: true },
      );
      assert.equal(mutation.status, 200);
      assert.equal((await mutation.json())[property], true);
    }
    const preferenceList = await (
      await fetch(
        `${base}/api/v1/entity-preferences?project=18&progressionTrack=Hardcore`,
      )
    ).json();
    assert.equal(preferenceList.preferences.length, 1);
    assert.equal(preferenceList.preferences[0].entityId, 987654321);
    assert.equal(preferenceList.preferences[0].pinned, true);
    assert.equal(preferenceList.preferences[0].hidden, true);

    const investigationResponse = await stateRequest(
      "/api/v1/saved-investigations",
      "POST",
      {
        name: "Published smoke",
        context,
        definitionVersion: 1,
        definition: {
          futureField: { preserve: true },
          periods: [
            { kind: "relative", days: 90 },
            { kind: "fixed", from: "2025-01-01", to: "2025-02-01" },
          ],
        },
      },
    );
    assert.equal(investigationResponse.status, 201);
    const investigation = await investigationResponse.json();
    const investigationPath = `/api/v1/saved-investigations/${investigation.id}`;
    const retrieved = await (await fetch(`${base}${investigationPath}`)).json();
    assert.equal(retrieved.revision, 1);
    assert.deepEqual(retrieved.definition.periods, [
      { kind: "relative", days: 90 },
      { kind: "fixed", from: "2025-01-01", to: "2025-02-01" },
    ]);
    const updatedResponse = await stateRequest(investigationPath, "PUT", {
      name: "Published smoke updated",
      definitionVersion: 2,
      definition: { futureField: { preserve: true } },
      revision: 1,
    });
    assert.equal(updatedResponse.status, 200);
    const updated = await updatedResponse.json();
    assert.equal(updated.name, "Published smoke updated");
    assert.equal(updated.definitionVersion, 2);
    assert.equal(updated.revision, 2);

    if (!options.includes("--skip-browser")) await smokeBrowser(base);
    child.kill("SIGINT");
    const [code, signal] = await exited;
    if (process.platform !== "win32") {
      assert.equal(code, 0, `Host did not stop gracefully (${signal}):\n${logs}`);
    }

    logs = "";
    child = spawn(
      binary,
      ["serve", "--monitoring", "false", "--require-port", "--port", `${port}`],
      { cwd: directory, env: environment, stdio: ["ignore", "pipe", "pipe"] },
    );
    captureLogs(child);
    exited = once(child, "exit");
    await waitUntilHealthy();
    const recoveredPreferences = await (
      await fetch(
        `${base}/api/v1/entity-preferences?project=18&progressionTrack=Hardcore`,
      )
    ).json();
    assert.equal(recoveredPreferences.preferences[0].pinned, true);
    assert.equal(recoveredPreferences.preferences[0].hidden, true);
    assert.deepEqual(
      (await (
        await fetch(`${base}${investigationPath}`)
      ).json()).definition,
      updated.definition,
    );
    assert(
      (await readdir(path.join(directory, "data"))).includes(
        "application-state.sqlite3",
      ),
    );
    console.log(
      "Single-executable smoke passed (fixture history and SQLite state).",
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
} finally {
  await rm(directory, { recursive: true, force: true });
}
