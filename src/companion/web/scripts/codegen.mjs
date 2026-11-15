import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

async function fingerprint(root, files) {
  const hash = createHash("sha256");
  for (const file of files.sort()) {
    hash.update(JSON.stringify(file));
    hash.update(await readFile(path.join(root, file)));
  }
  return hash.digest("hex");
}

async function generatedFiles(root) {
  const directory = "src/graphql/generated";
  const entries = await readdir(path.join(root, directory), {
    recursive: true,
    withFileTypes: true,
  });
  return [
    "src/api/generated.ts",
    ...entries
      .filter((entry) => entry.isFile())
      .map((entry) =>
        path.relative(root, path.join(entry.parentPath, entry.name)),
      ),
  ];
}

export async function ensureCodegen(root, generate) {
  const documents = (await readdir(path.join(root, "src/graphql")))
    .filter((name) => name.endsWith(".graphql"))
    .map((name) => `src/graphql/${name}`);
  const inputs = await fingerprint(root, [
    "codegen.ts",
    "package.json",
    "package-lock.json",
    "../src/Runtime/GraphQL/schema.graphql",
    "../src/Runtime/Api/Contracts/openapi.yaml",
    ...documents,
  ]);
  const stamp = path.join(root, "node_modules/.companion-codegen");
  try {
    const cached = JSON.parse(await readFile(stamp, "utf8"));
    if (
      cached.inputs === inputs &&
      cached.outputs === (await fingerprint(root, await generatedFiles(root)))
    ) {
      return false;
    }
  } catch (error) {
    if (error.code !== "ENOENT" && !(error instanceof SyntaxError)) throw error;
  }
  await generate();
  const outputs = await fingerprint(root, await generatedFiles(root));
  await writeFile(stamp, JSON.stringify({ inputs, outputs }));
  return true;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = fileURLToPath(new URL("../", import.meta.url));
  const generated = await ensureCodegen(root, () => {
    const result = spawnSync(
      process.platform === "win32" ? "npm.cmd" : "npm",
      ["run", "codegen"],
      { cwd: root, stdio: "inherit", shell: process.platform === "win32" },
    );
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error("API contract generation failed.");
  });
  if (!generated)
    console.log("API contracts unchanged; using generated files.");
}
