import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

export async function smokeBrowser(base) {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const failures = [];
  page.on("pageerror", (error) => failures.push(error.message));
  page.on("request", (request) => {
    if (new URL(request.url()).origin !== new URL(base).origin)
      failures.push(`Remote frontend dependency: ${request.url()}`);
  });
  try {
    const status = page.waitForResponse(
      (response) => new URL(response.url()).pathname === "/api/v1/status",
    );
    const history = page.waitForResponse(
      (response) => new URL(response.url()).pathname === "/graphql",
    );
    const document = await page.goto(new URL("/history", base).href);
    assert.equal(document.status(), 200);
    assert.equal((await status).status(), 200);
    const graph = await history;
    assert.equal(graph.status(), 200);
    const result = await graph.json();
    assert.equal(result.errors, undefined, JSON.stringify(result.errors));
    assert(result.data, "The browser must receive GraphQL data.");
    await page.waitForFunction(
      () => document.querySelector("#root")?.textContent?.trim().length > 0,
    );
    assert.deepEqual(failures, [], `Browser errors: ${failures.join("\n")}`);
    console.log("Browser smoke passed: rendered app, REST and GraphQL.");
  } finally {
    await browser.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  assert(
    process.argv[2],
    "Usage: npm run test:browser -- http://127.0.0.1:<port>",
  );
  await smokeBrowser(process.argv[2]);
}
