import assert from "node:assert/strict";
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
      `Browser smoke passed: ${label}${hotReload ? " (including Vite HMR)" : ""}`,
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
