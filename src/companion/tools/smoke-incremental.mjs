import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile, stat, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const dist = path.join(root, "web", "dist");
const index = path.join(dist, "index.html");
const web = path.join(root, "web");
const stamp = path.join(web, "node_modules", ".companion-production-restore");

function build() {
  const result = spawnSync(
    "dotnet",
    [
      "build",
      "src/WebAssets/WebAssets.csproj",
      "-c",
      "Release",
      "--no-restore",
      "-p:CompanionWebDevelopment=false",
      "-warnaserror",
    ],
    { cwd: root, encoding: "utf8" },
  );
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

build();
await writeFile(stamp, "incompatible-platform-or-node-version");
assert.match(
  build(),
  /restoring with npm ci/i,
  "An incompatible production restore must be replaced.",
);
assert.doesNotMatch(
  build(),
  /restoring with npm ci/i,
  "A compatible production restore must be reused.",
);
const install = spawnSync(
  process.platform === "win32" ? "npm.cmd" : "npm",
  ["run", "install:development"],
  { cwd: web, encoding: "utf8", shell: process.platform === "win32" },
);
assert.equal(install.status, 0, `${install.stdout}\n${install.stderr}`);
assert(
  !existsSync(stamp),
  "Development installation must invalidate production state.",
);
assert.match(
  build(),
  /restoring with npm ci/i,
  "Development installation must not count as a production restore.",
);
const vite = path.join(
  web,
  "node_modules",
  ".bin",
  process.platform === "win32" ? "vite.cmd" : "vite",
);
await unlink(vite);
assert.match(
  build(),
  /restoring with npm ci/i,
  "An incomplete dependency tree must be repaired.",
);
console.log(
  "Incompatible, development and incomplete npm states were restored.",
);
for (const extension of ["js", "css"]) {
  const html = await readFile(index, "utf8");
  const match = html.match(
    new RegExp(`(?:src|href)="(/assets/[^"]+\\.${extension})"`),
  );
  assert(match, `The document must reference a ${extension} asset.`);
  const asset = path.resolve(dist, match[1].slice(1));
  assert(
    asset.startsWith(dist + path.sep),
    "Only generated frontend assets may be removed.",
  );
  const original = await readFile(asset);
  await unlink(asset);
  try {
    assert.equal(
      await readFile(index, "utf8"),
      html,
      "The document is retained during the test.",
    );
    build();
    assert(
      existsSync(asset),
      `Incremental build did not recover the deleted ${extension} asset.`,
    );
    console.log(
      `Incremental build recovered the deleted ${extension} asset with index.html retained.`,
    );
  } finally {
    if (!existsSync(asset)) await writeFile(asset, original);
  }
}

assert.doesNotMatch(
  build(),
  /artisan-logbook-web@.* (?:build|postinstall)/,
  "An unchanged build must not restore or bundle the frontend again.",
);
console.log("Unchanged incremental build skipped npm restore and bundling.");

const sourceIndex = path.join(root, "web", "index.html");
const originalSource = await readFile(sourceIndex);
const originalTimestamp = (await stat(sourceIndex)).mtimeMs;
// Rewrite identical bytes without truncating the source or setting arbitrary
// timestamps, which may be forbidden on mounted development workspaces.
await writeFile(sourceIndex, originalSource, { flag: "r+" });
assert.deepEqual(await readFile(sourceIndex), originalSource);
assert(
  (await stat(sourceIndex)).mtimeMs > originalTimestamp,
  "Rewriting the source must advance its modification timestamp.",
);
assert.match(
  build(),
  /artisan-logbook-web@.* build/,
  "A newer source timestamp must trigger a frontend build.",
);
assert.doesNotMatch(
  build(),
  /artisan-logbook-web@.* (?:build|postinstall)/,
  "Unchanged asset names must not leave the output-list timestamp stale.",
);
console.log("Source timestamp changes do not cause repeated frontend builds.");
