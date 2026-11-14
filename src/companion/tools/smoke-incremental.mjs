import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile, stat, unlink, utimes, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const dist = path.join(root, "web", "dist");
const index = path.join(dist, "index.html");

function build() {
  const result = spawnSync(
    "dotnet",
    [
      "build",
      "src/WebAssets/WebAssets.csproj",
      "-c",
      "Release",
      "--no-restore",
      "-warnaserror",
    ],
    { cwd: root, encoding: "utf8" },
  );
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

build();
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
const timestamps = await stat(sourceIndex);
try {
  const now = new Date();
  await utimes(sourceIndex, now, now);
  build();
  assert.doesNotMatch(
    build(),
    /artisan-logbook-web@.* (?:build|postinstall)/,
    "Unchanged asset names must not leave the output-list timestamp stale.",
  );
  console.log(
    "Source timestamp changes do not cause repeated frontend builds.",
  );
} finally {
  await utimes(sourceIndex, timestamps.atime, timestamps.mtime);
}
