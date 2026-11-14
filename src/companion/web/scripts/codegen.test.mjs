import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ensureCodegen } from "./codegen.mjs";

describe("development contract generation", () => {
  let directory;
  let root;
  let generate;

  async function put(file, contents) {
    const target = path.join(root, file);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, contents);
  }

  beforeEach(async () => {
    directory = await mkdtemp(path.join(tmpdir(), "artisan-codegen-"));
    root = path.join(directory, "web");
    await mkdir(path.join(root, "node_modules"), { recursive: true });
    for (const file of [
      "codegen.ts",
      "package.json",
      "package-lock.json",
      "../src/Runtime/GraphQL/schema.graphql",
      "../src/Runtime/Api/Contracts/openapi.yaml",
      "src/graphql/crafts.graphql",
    ]) {
      await put(file, "original");
    }
    generate = vi.fn(async () => {
      await put("src/graphql/generated/graphql.ts", "generated GraphQL");
      await put("src/api/generated.ts", "generated REST");
    });
  });

  afterEach(async () => {
    await rm(directory, { recursive: true, force: true });
  });

  it("generates once and skips unchanged starts", async () => {
    expect(await ensureCodegen(root, generate)).toBe(true);
    expect(await ensureCodegen(root, generate)).toBe(false);
    expect(generate).toHaveBeenCalledTimes(1);
  });

  it.each([
    "codegen.ts",
    "package-lock.json",
    "../src/Runtime/GraphQL/schema.graphql",
    "../src/Runtime/Api/Contracts/openapi.yaml",
    "src/graphql/crafts.graphql",
    "src/graphql/new.graphql",
    "src/api/generated.ts",
  ])("regenerates when %s changes", async (file) => {
    await ensureCodegen(root, generate);
    await put(file, "changed");
    expect(await ensureCodegen(root, generate)).toBe(true);
    expect(generate).toHaveBeenCalledTimes(2);
  });

  it.each([
    "src/graphql/crafts.graphql",
    "src/graphql/generated/graphql.ts",
    "src/api/generated.ts",
    "node_modules/.companion-codegen",
  ])("regenerates when %s is deleted", async (file) => {
    await ensureCodegen(root, generate);
    await rm(path.join(root, file));
    expect(await ensureCodegen(root, generate)).toBe(true);
    expect(generate).toHaveBeenCalledTimes(2);
  });

  it("does not cache failed generation", async () => {
    await expect(
      ensureCodegen(root, async () => {
        throw new Error("generation failed");
      }),
    ).rejects.toThrow("generation failed");
    expect(await ensureCodegen(root, generate)).toBe(true);
  });
});
