import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const stamp = path.join(root, "node_modules/.companion-production-restore");
const npm = process.platform === "win32" ? "npm.cmd" : "npm";
function run(command, args, extra = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    shell: process.platform === "win32" && command === npm,
    ...extra,
  });
  if (result.error) throw result.error;
  return result;
}

const version = run(npm, ["--version"], { encoding: "utf8" });
if (version.status !== 0) throw new Error("Cannot determine npm version.");
const npmVersion = version.stdout.trim();
const [major, minor, patch] = process.versions.node.split(".").map(Number);
if (
  major !== 26 ||
  minor < 13 ||
  (minor === 13 && patch < 1) ||
  !/^11\./.test(npmVersion)
) {
  throw new Error(
    `Production frontend requires Node.js >=26.13.1 <27 and npm 11; found Node ${process.versions.node}, npm ${npmVersion}.`,
  );
}

function fingerprint() {
  const hash = createHash("sha256");
  hash.update(
    JSON.stringify({
      platform: process.platform,
      arch: process.arch,
      versions: process.versions,
      npmVersion,
      glibc: process.report.getReport().header.glibcVersionRuntime ?? null,
    }),
  );
  for (const file of [
    "package.json",
    "package-lock.json",
    "node_modules/.package-lock.json",
  ]) {
    hash.update(readFileSync(path.join(root, file)));
  }
  return hash.digest("hex");
}

function complete() {
  const suffix = process.platform === "win32" ? ".cmd" : "";
  if (
    !["vite", "tsc", "graphql-codegen", "openapi-typescript"].every((name) =>
      existsSync(path.join(root, "node_modules/.bin", name + suffix)),
    )
  ) {
    return false;
  }
  if (
    run(
      npm,
      ["ls", "--all", "--include=dev", "--include=optional", "--parseable"],
      {
        stdio: "ignore",
      },
    ).status !== 0
  ) {
    return false;
  }
  return (
    run(process.execPath, ["--input-type=module", "-e", "import('rolldown')"], {
      stdio: "ignore",
    }).status === 0
  );
}

let valid = false;
try {
  valid = readFileSync(stamp, "utf8") === fingerprint() && complete();
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
if (valid) {
  console.log("Production npm dependencies are current.");
} else {
  console.log(
    "Production npm state is missing, incompatible, or incomplete; restoring with npm ci.",
  );
  rmSync(stamp, { force: true });
  const result = run(
    npm,
    [
      "ci",
      "--include=dev",
      "--include=optional",
      "--ignore-scripts=false",
      `--os=${process.platform}`,
      `--cpu=${process.arch}`,
      "--no-audit",
      "--no-fund",
    ],
    { stdio: "inherit" },
  );
  if (result.status !== 0) {
    throw new Error(`npm ci failed (exit ${result.status ?? "unknown"}).`);
  }
  if (!complete()) {
    throw new Error(
      "npm ci completed but frontend executables or native bindings are missing.",
    );
  }
  writeFileSync(stamp, fingerprint());
}
