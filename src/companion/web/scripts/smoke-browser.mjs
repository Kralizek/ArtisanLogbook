import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, errors } from "playwright";

export async function smokeBrowser(base, label, hotReload = false) {
  const browser = await chromium.launch();
  const page = await browser.newPage({
    viewport: { width: 1280, height: 800 },
  });
  const failures = [];
  const apiResponses = [];
  const developmentMessages = [];
  const isApi = (url) =>
    /^\/(?:api\/v1(?:\/|$)|graphql$)/.test(new URL(url).pathname);
  page.on("pageerror", (error) => failures.push(error.message));
  page.on("console", (message) => {
    if (message.text().includes("[vite]"))
      developmentMessages.push(message.text());
  });
  page.on("websocket", (socket) => {
    socket.on("framereceived", ({ payload }) =>
      developmentMessages.push(String(payload)),
    );
    socket.on("socketerror", (error) =>
      developmentMessages.push(String(error)),
    );
  });
  page.on("request", (request) => {
    if (new URL(request.url()).origin !== new URL(base).origin)
      failures.push(`Remote frontend dependency: ${request.url()}`);
    if (
      isApi(request.url()) &&
      request.headers()["x-artisan-logbook-client"] !== "web"
    )
      failures.push(`Missing web client header: ${request.url()}`);
  });
  page.on("response", (response) => {
    if (isApi(response.url())) apiResponses.push(response.status());
  });
  const screenshots = process.env.SMOKE_SCREENSHOTS_DIRECTORY;
  async function screenshot(name) {
    if (!screenshots) return;
    await mkdir(screenshots, { recursive: true });
    await page.screenshot({
      path: path.join(screenshots, `${label}-${name}.png`),
    });
  }
  try {
    await page.goto(base);
    await page.getByRole("heading", { name: "Canonical history" }).waitFor();
    await screenshot("overview");
    await page.getByRole("link", { name: "Recent crafts" }).click();
    await page.getByRole("heading", { name: "Recent crafts" }).waitFor();
    await page.getByLabel("Loading recent crafts").waitFor({ state: "hidden" });
    assert(
      (await page.getByRole("table").count()) ||
        (await page.getByText("No recorded crafts yet.").count()),
    );
    await screenshot("history");
    await page.reload();
    await page.getByRole("heading", { name: "Recent crafts" }).waitFor();
    await page.getByLabel("Loading recent crafts").waitFor({ state: "hidden" });
    await page.getByRole("button", { name: "Light / dark" }).click();
    await page.setViewportSize({ width: 560, height: 800 });
    await page.getByRole("button", { name: "Toggle navigation" }).click();
    await page
      .getByRole("link", { name: "Overview" })
      .waitFor({ state: "visible" });
    await page.getByRole("link", { name: "Overview" }).click();
    await page.getByRole("heading", { name: "Companion overview" }).waitFor();
    if (hotReload) {
      await page.setViewportSize({ width: 1280, height: 800 });
      let navigations = 0;
      page.on("request", (request) => {
        if (
          request.isNavigationRequest() &&
          request.frame() === page.mainFrame()
        )
          navigations++;
      });
      const home = fileURLToPath(
        new URL("../src/pages/Home.tsx", import.meta.url),
      );
      const originalHome = await readFile(home, "utf8");
      try {
        assert(originalHome.includes(">Companion overview<"));
        await writeFile(
          home,
          originalHome.replace(
            ">Companion overview<",
            ">Fast Refresh verified<",
          ),
        );
        await page
          .getByRole("heading", { name: "Fast Refresh verified" })
          .waitFor();
        assert.equal(navigations, 0, "React changes must not reload the page");
      } finally {
        await writeFile(home, originalHome);
      }
      await page.getByRole("heading", { name: "Companion overview" }).waitFor();
      const css = fileURLToPath(
        new URL("../src/styles/app.css", import.meta.url),
      );
      const original = await readFile(css, "utf8");
      try {
        await writeFile(
          css,
          `${original}\nbody { outline: rgb(1, 2, 3) solid 1px; }\n`,
        );
        try {
          await page.waitForFunction(
            () =>
              getComputedStyle(document.body).outlineColor === "rgb(1, 2, 3)",
          );
        } catch (error) {
          if (!(error instanceof errors.TimeoutError)) throw error;
          throw new Error(
            `Vite CSS update was not applied. ${developmentMessages.join("\n")}`,
            { cause: error },
          );
        }
      } finally {
        await writeFile(css, original);
      }
      const operation = fileURLToPath(
        new URL("../src/graphql/recent-crafts.graphql", import.meta.url),
      );
      const originalOperation = await readFile(operation, "utf8");
      function runNpmScript(script) {
        execFileSync(
          process.platform === "win32" ? "npm.cmd" : "npm",
          ["run", script],
          {
            cwd: fileURLToPath(new URL("../", import.meta.url)),
            shell: process.platform === "win32",
            stdio: "pipe",
            encoding: "utf8",
          },
        );
      }
      try {
        assert(originalOperation.includes("first: 20"));
        assert(originalOperation.includes("concentrationSpent"));
        await writeFile(
          operation,
          originalOperation
            .replace("first: 20", "first: 2")
            .replace(
              "concentrationSpent",
              "concentrationSpent: ingenuityRefund",
            ),
        );
        runNpmScript("codegen");
        const generated = await readFile(
          new URL("../src/graphql/generated/graphql.ts", import.meta.url),
          "utf8",
        );
        assert.match(generated, /"value":"ingenuityRefund"/);
        runNpmScript("typecheck");
        const changedRequest = page.waitForRequest(
          (request) =>
            new URL(request.url()).pathname === "/graphql" &&
            request.postDataJSON().query.includes("ingenuityRefund"),
        );
        await page.getByRole("link", { name: "Recent crafts" }).click();
        const firstResponse = await (await changedRequest).response();
        const firstPage = await firstResponse.json();
        await page
          .getByLabel("Loading recent crafts")
          .waitFor({ state: "hidden" });
        assert.equal(await page.locator("tbody tr").count(), 2);
        const nextPage = page.waitForResponse(
          (response) =>
            new URL(response.url()).pathname === "/graphql" &&
            response.request().postDataJSON().variables.after ===
              firstPage.data.crafts.pageInfo.endCursor,
        );
        await page.getByRole("button", { name: "Next page" }).click();
        const next = await (await nextPage).json();
        assert.notEqual(
          next.data.crafts.nodes[0].id,
          firstPage.data.crafts.nodes[0].id,
        );
        await page
          .getByLabel("Loading recent crafts")
          .waitFor({ state: "hidden" });
        const refreshed = page.waitForRequest(
          (request) => new URL(request.url()).pathname === "/graphql",
        );
        await page
          .getByRole("button", { name: "Refresh", exact: true })
          .click();
        await refreshed;
        await page
          .getByLabel("Loading recent crafts")
          .waitFor({ state: "hidden" });
        const newestPage = page.waitForResponse(
          (response) =>
            new URL(response.url()).pathname === "/graphql" &&
            !response.request().postDataJSON().variables.after,
        );
        await page.getByRole("button", { name: "Newest", exact: true }).click();
        const newest = await (await newestPage).json();
        await page
          .getByLabel("Loading recent crafts")
          .waitFor({ state: "hidden" });
        assert.equal(
          newest.data.crafts.nodes[0].id,
          firstPage.data.crafts.nodes[0].id,
        );
      } finally {
        await writeFile(operation, originalOperation);
        runNpmScript("codegen");
      }
      assert.equal(navigations, 0, "Frontend edits must not reload the page");
    }
    assert.deepEqual(
      failures,
      [],
      `Browser initialization errors: ${failures.join("\n")}`,
    );
    assert(apiResponses.length >= 2);
    assert(
      apiResponses.every((status) => status === 200),
      `API statuses: ${apiResponses}`,
    );
    console.log(
      `Browser smoke passed: ${label}${hotReload ? " (React/CSS HMR, regenerated GraphQL, pagination and refresh)" : ""}`,
    );
  } finally {
    await browser.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  assert(
    process.argv[2],
    "Usage: npm run test:browser -- http://127.0.0.1:<port>",
  );
  await smokeBrowser(process.argv[2], "manual");
}
