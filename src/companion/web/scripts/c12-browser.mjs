import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

// Run only against an isolated Companion with scripts/fixtures/investigations.lua
// imported through the CLI, after stopping the writer. Never point at player data.
const fixture = {
  total: 6,
  retail: 5,
  forever: 1,
  recentRetail: 4,
  recipe: "Artisan Potion",
  archived: "Archived Elixir",
  input: "Wild Mote",
  recipeId: 1230868,
  archivedAt: "2026-05-15",
  secondCharacterAt: "2026-11-07",
};
const asOf = new Date("2026-11-15T12:00:00.000Z");

function urlAt(base, route) {
  return new URL(route, base).href;
}

async function json(response, description) {
  assert.equal(response.status, 200, `${description}: HTTP ${response.status}`);
  return response.json();
}

async function preflight(base) {
  const headers = { Origin: base.origin, "X-Artisan-Logbook-Client": "web" };
  const status = await json(
    await fetch(urlAt(base, "/api/v1/status"), { headers }),
    "Companion status",
  );
  assert.equal(
    status.history?.craftCount,
    fixture.total,
    "Refusing to mutate data: use a fresh, isolated directory containing ONLY the imported C12 fixture (6 crafts).",
  );
  assert.deepEqual(
    status.history.gameContexts
      .map(({ context, craftCount }) => [context.project, craftCount])
      .sort((a, b) => a[0] - b[0]),
    [
      [1, fixture.retail],
      [18, fixture.forever],
    ],
    "The imported fixture needs five Retail crafts and one Forever craft.",
  );
  assert.equal(
    status.applicationState?.available,
    true,
    "Personal organization must be available.",
  );
  const contextIds = {};
  for (const context of ["retail", "forever"]) {
    const meta = await json(
      await fetch(urlAt(base, `/api/v1/games/${context}`), { headers }),
      `${context} context metadata`,
    );
    assert(meta.canonicalId && meta.routeAlias === context);
    contextIds[context] = meta.canonicalId;
    for (const collection of ["entity-preferences", "saved-investigations"]) {
      const body = await json(
        await fetch(urlAt(base, `/api/v1/games/${context}/${collection}`), {
          headers,
        }),
        `${context} ${collection}`,
      );
      assert.equal(
        body[
          collection === "entity-preferences" ? "preferences" : "investigations"
        ].length,
        0,
        "Refusing to mutate data: organization state must also be empty.",
      );
    }
  }
  const query = async (document, variables) => {
    const response = await fetch(urlAt(base, "/graphql"), {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify({ query: document, variables }),
    });
    const body = await json(response, "C12 GraphQL fixture");
    assert.equal(
      body.errors,
      undefined,
      `GraphQL fixture preflight: ${JSON.stringify(body.errors)}`,
    );
    assert(body.data, "GraphQL fixture returned no data.");
    return body.data;
  };
  const catalog = `
    query C12FixtureCatalog($context: String!, $recent: CraftFilterInput!) {
      game(context: $context) {
        canonicalId
        characters(first: 100) { nodes { name id } }
        recipes(first: 20, search: "Artisan Potion") { nodes { id blizzardId name } }
        archived: recipes(first: 20, search: "Archived Elixir") { nodes { id name } }
        items(first: 20, search: "Wild Mote") { nodes { id name } }
      }
      all: analysis(context: $context) {
        attempts { attempts }
        supportsReturns
        inputMeasureLabel
      }
      recent: analysis(context: $context, filter: $recent) {
        attempts { attempts }
        recipes { nodes { name } }
      }
    }`;
  const recent = {
    from: new Date(asOf.getTime() - 30 * 86400000).toISOString(),
    to: asOf.toISOString(),
  };
  const retail = await query(catalog, { context: contextIds.retail, recent });
  const forever = await query(catalog, { context: contextIds.forever, recent });
  assert.equal(retail.all.attempts.attempts, String(fixture.retail));
  assert.equal(
    retail.recent.attempts.attempts,
    String(fixture.recentRetail),
    "Fixture's November 2026 crafts must be within 30 days of the fixed acceptance clock.",
  );
  assert.equal(forever.all.attempts.attempts, String(fixture.forever));
  assert.equal(retail.game.characters.nodes.length, 3);
  assert(retail.game.characters.nodes.some((node) => node.name === "Torren"));
  assert.equal(forever.game.characters.nodes.length, 1);
  assert.equal(
    retail.game.archived.nodes.length,
    1,
    "Archived recipe must remain searchable.",
  );
  assert(
    !retail.recent.recipes.nodes.some((node) => node.name === fixture.archived),
    "Archived recipe must be absent from the last 30 days.",
  );
  assert(
    new Date(fixture.archivedAt).getTime() < asOf.getTime() - 30 * 86400000,
  );
  assert.equal(retail.game.items.nodes.length, 1);
  assert.equal(forever.game.items.nodes.length, 1);
  const recipe = retail.game.recipes.nodes.find(
    (node) => node.blizzardId === fixture.recipeId,
  );
  const otherRecipe = forever.game.recipes.nodes.find(
    (node) => node.blizzardId === fixture.recipeId,
  );
  assert(
    recipe?.id && otherRecipe?.id && recipe.id !== otherRecipe.id,
    "Overlapping Blizzard recipe IDs must resolve to distinct opaque context identities.",
  );
  assert.equal(retail.all.supportsReturns, true);
  assert.equal(forever.all.supportsReturns, false);
  assert.match(
    forever.all.inputMeasureLabel,
    /attributed schematic requirements/i,
  );
  const configured = await query(
    `
    query C12FixtureConfigurations($context: String!, $filter: CraftFilterInput!) {
      analysis(context: $context, filter: $filter) {
        configurations { nodes { id evidenceAvailable } }
      }
    }`,
    { context: contextIds.retail, filter: { recipeId: recipe.id } },
  );
  assert(
    configured.analysis.configurations.nodes.length >= 2 &&
      configured.analysis.configurations.nodes.every(
        (node) => node.evidenceAvailable,
      ),
    "Import must preserve both recorded Retail configuration variants.",
  );
  return {
    recipeId: recipe.id,
    archivedId: retail.game.archived.nodes[0].id,
    otherRecipeId: otherRecipe.id,
    inputId: retail.game.items.nodes[0].id,
  };
}

function attachDiagnostics(page, base, diagnostics) {
  let navigation = 0;
  page.on("framenavigated", (frame) => {
    if (frame === page.mainFrame()) navigation++;
  });
  page.on("pageerror", (error) => diagnostics.pageErrors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error")
      diagnostics.consoleErrors.push(message.text());
  });
  page.on("request", (request) => {
    if (new URL(request.url()).origin !== base.origin)
      diagnostics.remoteRequests.push(request.url());
  });
  page.on("requestfailed", (request) => {
    const failure = request.failure()?.errorText ?? "unknown error";
    if (!/ERR_ABORTED|NS_BINDING_ABORTED/.test(failure))
      diagnostics.networkErrors.push(
        `${request.method()} ${new URL(request.url()).pathname}: ${failure}`,
      );
  });
  page.on("response", (response) => {
    const pathname = new URL(response.url()).pathname;
    if (
      response.status() >= 400 &&
      (/^\/api\//.test(pathname) || pathname === "/graphql")
    )
      diagnostics.networkErrors.push(`${response.status()} ${pathname}`);
    if (pathname === "/graphql") {
      const observedNavigation = navigation;
      void response
        .json()
        .then((body) => {
          if (body.errors?.length)
            diagnostics.networkErrors.push(
              `GraphQL: ${JSON.stringify(body.errors)}`,
            );
        })
        .catch((error) => {
          if (
            /No resource with given identifier found|Response body is not available/.test(
              error.message,
            ) &&
            (page.isClosed() || navigation !== observedNavigation)
          ) {
            diagnostics.navigationAborts.push(
              "A GraphQL response body was discarded by completed navigation.",
            );
          } else
            diagnostics.networkErrors.push(
              `GraphQL response: ${error.message}`,
            );
        });
    }
  });
}

async function route(page, pathname, parameters = {}) {
  await page.waitForURL((value) => value.pathname === pathname, {
    timeout: 15000,
  });
  const current = new URL(page.url());
  for (const [key, value] of Object.entries(parameters))
    assert.equal(
      current.searchParams.get(key),
      value,
      `${key} in ${page.url()}`,
    );
  return current;
}

async function attempts(page, expected) {
  const count = page
    .locator("main .mantine-Card-root")
    .filter({ has: page.getByText("Completed attempts", { exact: true }) })
    .locator(".metric-value");
  await count.getByText(expected, { exact: true }).waitFor();
}

async function select(page, name, option) {
  await page.waitForLoadState("networkidle");
  await page.getByRole("combobox", { name, exact: true }).click();
  await page.getByRole("option", { name: option, exact: true }).click();
}

function outcomeRow(page) {
  return page
    .getByRole("table")
    .filter({
      has: page.getByRole("columnheader", { name: "Observed outcome" }),
    })
    .getByRole("row")
    .filter({
      has: page.getByRole("cell", { name: "Completed attempts", exact: true }),
    });
}

async function comparison(page, first, second) {
  const row = outcomeRow(page);
  await row
    .getByRole("cell")
    .nth(2)
    .getByText(second, { exact: true })
    .waitFor();
  await row
    .getByRole("cell")
    .nth(1)
    .getByText(first, { exact: true })
    .waitFor();
}

async function capture(page, output, label, width) {
  await page.setViewportSize({ width, height: 900 });
  await page.screenshot({
    path: path.join(
      output,
      `${width === 1440 ? "desktop" : "narrow"}-${label}.png`,
    ),
    fullPage: true,
  });
}

async function run(base, output) {
  const ids = await preflight(base);
  await mkdir(output, { recursive: true });
  const diagnostics = {
    navigationAborts: [],
    pageErrors: [],
    consoleErrors: [],
    networkErrors: [],
    remoteRequests: [],
    steps: [],
    manualFollowUp: [
      "Stop the isolated writer, reimport the same fixture, restart Companion, and verify canonical craft totals, saved definitions and preference revisions remain stable.",
      "With a separate isolated data directory, simulate unavailable application state and failed history reads; check errors, retry, preserved URL scope and no loss of unsaved edits.",
      "Review narrow screenshots for table scrolling, shell navigation and keyboard/screen-reader usability; screenshots are not an accessibility audit.",
    ],
  };
  const browser = await chromium.launch();
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
  });
  const page = await context.newPage();
  await page.clock.setFixedTime(asOf);
  attachDiagnostics(page, base, diagnostics);
  let step = "open Activity";
  try {
    const mark = (name) => {
      step = name;
      diagnostics.steps.push(name);
      console.log(`C12: ${name}`);
    };
    mark("open real Retail activity");
    assert.equal(
      (await page.goto(urlAt(base, "/retail/activity?period=all"))).status(),
      200,
    );
    await route(page, "/retail/activity", { period: "all" });
    await attempts(page, "5");
    mark("journal shell wraps without overlap in both themes");
    for (const scheme of ["light", "dark"]) {
      if (
        (await page
          .locator("html")
          .getAttribute("data-mantine-color-scheme")) !== scheme
      )
        await page.getByRole("button", { name: "Light / dark" }).click();
      const textContrast = await page.evaluate(() => {
        function luminance(color) {
          const channels = color
            .match(/[\d.]+/g)
            .slice(0, 3)
            .map(Number)
            .map((value) => {
              const channel = value / 255;
              return channel <= 0.04045
                ? channel / 12.92
                : ((channel + 0.055) / 1.055) ** 2.4;
            });
          return (
            channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
          );
        }
        function ratio(foreground, background) {
          const values = [luminance(foreground), luminance(background)].sort(
            (a, b) => b - a,
          );
          return (values[0] + 0.05) / (values[1] + 0.05);
        }
        const eyebrow = document.querySelector(".eyebrow");
        const navigation = document.querySelector(".mantine-AppShell-navbar");
        const hint = [...navigation.querySelectorAll("p")].find((element) =>
          element.textContent.includes("Pin recipes to keep"),
        );
        return {
          eyebrow: ratio(
            getComputedStyle(eyebrow).color,
            getComputedStyle(document.body).backgroundColor,
          ),
          navigationHint: ratio(
            getComputedStyle(hint).color,
            getComputedStyle(navigation).backgroundColor,
          ),
        };
      });
      for (const [label, ratio] of Object.entries(textContrast))
        assert(
          ratio >= 4.5,
          `${scheme} ${label} contrast must meet 4.5:1 (actual ${ratio})`,
        );
      for (const width of [390, 768, 1280, 1440]) {
        await page.setViewportSize({ width, height: 900 });
        await page.evaluate(() => window.scrollTo(0, 0));
        await page.waitForTimeout(100);
        const header = await page
          .locator(".mantine-AppShell-header")
          .boundingBox();
        const heading = await page
          .getByRole("heading", { name: "Overview", exact: true })
          .boundingBox();
        assert(
          header && heading && heading.y >= header.y + header.height,
          `${scheme} ${width}px header must not overlap Overview`,
        );
        assert(
          await page.evaluate(
            () => document.documentElement.scrollWidth <= window.innerWidth + 1,
          ),
          `${scheme} ${width}px must not overflow the viewport`,
        );
        if (width >= 1280)
          assert(
            await page.evaluate(
              () => document.documentElement.scrollHeight < 2200,
            ),
            "Overview must be bounded, not a wall of reports",
          );
        await page.screenshot({
          path: path.join(output, `journal-${scheme}-${width}.png`),
          fullPage: true,
        });
      }
    }
    await page.getByRole("button", { name: "Light / dark" }).click();
    await capture(page, output, "activity", 1440);
    await capture(page, output, "activity", 760);
    await page.setViewportSize({ width: 1440, height: 900 });

    mark(
      "last 30 days excludes the old recipe, but context-wide search finds it",
    );
    await select(page, "Period", "Last 30 days");
    await route(page, "/retail/activity", { period: "30" });
    await attempts(page, "4");
    assert.equal(
      await page
        .getByRole("main")
        .getByRole("link", { name: fixture.archived })
        .count(),
      0,
    );
    await page
      .getByRole("textbox", { name: /Search recipes and items in Retail/i })
      .fill(fixture.archived);
    const archived = page
      .getByRole("region", { name: "Search results" })
      .getByRole("link", { name: "Recipe Archived Elixir", exact: true });
    await archived.waitFor();
    assert.equal(
      new URL(await archived.getAttribute("href"), base).searchParams.get(
        "period",
      ),
      "all",
    );
    await archived.click();
    await page
      .getByRole("heading", { name: fixture.archived, exact: true })
      .waitFor();
    await route(page, `/retail/recipes/${encodeURIComponent(ids.archivedId)}`, {
      period: "all",
    });
    await page.getByRole("tab", { name: "Statistics", exact: true }).click();
    await outcomeRow(page)
      .getByRole("cell")
      .nth(1)
      .getByText("1", { exact: true })
      .waitFor();
    await page.goBack();
    await route(page, "/retail/activity", { period: "30" });
    await attempts(page, "4");

    mark("URL scope follows overview → recipe → item → crafts, with history");
    await select(page, "Period", "Last 90 days");
    await route(page, "/retail/activity", { period: "90" });
    await attempts(page, "4");
    const recipeLink = page
      .getByRole("main")
      .getByRole("link", { name: fixture.recipe, exact: true })
      .first();
    const opened = context.waitForEvent("page");
    await recipeLink.click({ modifiers: ["Control"] });
    const linkTab = await opened;
    attachDiagnostics(linkTab, base, diagnostics);
    await route(
      linkTab,
      `/retail/recipes/${encodeURIComponent(ids.recipeId)}`,
      {
        period: "90",
      },
    );
    assert.equal(
      new URL(page.url()).pathname,
      "/retail/activity",
      "Opening a link in another tab must not navigate the original tab.",
    );
    await linkTab.waitForLoadState("networkidle");
    await linkTab.close();
    await recipeLink.click();
    await route(page, `/retail/recipes/${encodeURIComponent(ids.recipeId)}`, {
      period: "90",
    });
    await page
      .getByRole("heading", { name: fixture.recipe, exact: true })
      .waitFor();
    await select(page, "Period", "Last 30 days");
    const recipeUrl = await route(
      page,
      `/retail/recipes/${encodeURIComponent(ids.recipeId)}`,
      { period: "30" },
    );
    await page.getByRole("tab", { name: "Statistics", exact: true }).click();
    await outcomeRow(page)
      .getByRole("cell")
      .nth(1)
      .getByText("3", { exact: true })
      .waitFor();
    await page.getByRole("tab", { name: "Overview", exact: true }).click();
    await capture(page, output, "recipe", 1440);
    await capture(page, output, "recipe", 760);
    await page.setViewportSize({ width: 1440, height: 900 });
    await page
      .getByRole("heading", { name: "Actual output items" })
      .locator("..")
      .getByRole("link", { name: fixture.recipe, exact: true })
      .click();
    await page
      .getByRole("heading", { name: fixture.recipe, exact: true })
      .waitFor();
    const outputCard = page.locator("main .mantine-Card-root").filter({
      has: page.getByRole("heading", { name: "Actual output", exact: true }),
    });
    await outputCard.getByText("3 matching attempts").waitFor();
    await capture(page, output, "output-item", 1440);
    await page.goBack();
    await route(page, recipeUrl.pathname, { period: "30" });
    await page.getByRole("tab", { name: "Reagents", exact: true }).click();
    await page
      .getByRole("main")
      .getByRole("link", { name: fixture.input, exact: true })
      .first()
      .click();
    const itemUrl = await route(
      page,
      `/retail/items/${encodeURIComponent(ids.inputId)}`,
      { period: "30" },
    );
    await page
      .getByRole("heading", { name: fixture.input, exact: true })
      .waitFor();
    await page
      .getByRole("heading", { name: "Gross allocated inputs", level: 2 })
      .waitFor();
    await capture(page, output, "item", 1440);
    await capture(page, output, "item", 760);
    await page.setViewportSize({ width: 1440, height: 900 });
    const inputCard = page.locator("main .mantine-Card-root").filter({
      has: page.getByRole("heading", {
        name: "Gross allocated inputs",
        level: 2,
      }),
    });
    await inputCard.getByText("9", { exact: true }).waitFor();
    await inputCard
      .getByRole("link", { name: "Inspect contributing crafts" })
      .click();
    const craftsUrl = await route(page, "/retail/crafts", {
      period: "30",
      input: ids.inputId,
    });
    await page.getByRole("heading", { name: "Logbook", exact: true }).waitFor();
    await page
      .getByRole("link", { name: fixture.recipe, exact: true })
      .first()
      .waitFor();
    await capture(page, output, "crafts", 1440);
    await page.locator("main a:has(time)").first().click();
    await page.getByRole("heading", { name: "Completed craft" }).waitFor();
    await page.getByRole("tab", { name: "Ingredients", exact: true }).click();
    await page.getByRole("heading", { name: "Reagents and returns" }).waitFor();
    await page.getByRole("tab", { name: "Configuration", exact: true }).click();
    await page
      .getByRole("heading", { name: "Recorded setup evidence" })
      .waitFor();
    await capture(page, output, "craft-evidence", 1440);
    await page.goBack();
    await route(page, craftsUrl.pathname, { period: "30", input: ids.inputId });
    for (const expected of [
      itemUrl,
      recipeUrl,
      new URL(urlAt(base, "/retail/activity?period=90")),
    ]) {
      await page.goBack();
      await route(page, expected.pathname, {
        period: expected.searchParams.get("period"),
      });
      assert.equal(
        page.url(),
        expected.href,
        "Back must restore the exact scoped URL.",
      );
    }
    for (const expected of [recipeUrl, itemUrl, craftsUrl]) {
      await page.goForward();
      await route(page, expected.pathname, { period: "30" });
      assert.equal(
        page.url(),
        expected.href,
        "Forward must restore the exact scoped URL.",
      );
    }
    await page.goBack();
    await page.goBack();
    await route(page, recipeUrl.pathname, { period: "30" });

    mark(
      "independent comparison, character, period and recorded configuration",
    );
    await page
      .getByRole("tab", { name: "Compare setups", exact: true })
      .click();
    await select(page, "What would you like to compare?", "Custom populations");
    await page
      .getByRole("button", { name: "Compare setups", exact: true })
      .click();
    await page
      .getByRole("button", {
        name: "Advanced · independent population filters",
      })
      .click();
    await select(page, "Population B Period", "Fixed dates");
    await page
      .getByLabel("Population B From", { exact: true })
      .fill(fixture.secondCharacterAt);
    await page
      .getByLabel("Population B Through", { exact: true })
      .fill(fixture.secondCharacterAt);
    await page.getByRole("button", { name: "Apply dates" }).click();
    await page.waitForURL((value) => value.searchParams.has("bto"));
    await page
      .getByRole("button", {
        name: "Advanced · independent population filters",
      })
      .click();
    await select(page, "Population B Character", "Torren");
    await route(page, recipeUrl.pathname, {
      period: "30",
      compare: "1",
      bperiod: "fixed",
      bfrom: fixture.secondCharacterAt,
      bto: fixture.secondCharacterAt,
    });
    await comparison(page, "3", "1");
    await page
      .getByRole("button", { name: "Inspect recorded setup variants" })
      .click();
    await page
      .getByRole("heading", { name: "Recorded configurations" })
      .waitFor();
    await page
      .getByRole("button", { name: "More filters", exact: true })
      .click();
    const variant = page.getByRole("combobox", {
      name: "Recorded setup",
      exact: true,
    });
    await variant.click();
    await page
      // The fixture's two Retail setups differ by skill; the skill-120 setup has two of A's attempts.
      .getByRole("option", { name: /Recorded setup .* · skill 120/ })
      .click();
    assert(new URL(page.url()).searchParams.has("configuration"));
    await comparison(page, "2", "1");
    await capture(page, output, "comparison", 1440);
    await capture(page, output, "comparison", 760);
    await page.setViewportSize({ width: 1440, height: 900 });

    mark("pin, hide and restore preserve factual totals");
    await page.getByRole("button", { name: "Pin", exact: true }).click();
    await page.getByRole("button", { name: "Unpin", exact: true }).waitFor();
    await page.getByRole("button", { name: "Hide", exact: true }).click();
    await page.getByRole("button", { name: "Reveal", exact: true }).waitFor();
    const comparisonUrl = page.url();
    await page.goto(urlAt(base, "/retail/activity?period=30"));
    await attempts(page, "4");
    assert.equal(
      await page
        .getByRole("main")
        .locator('a[href*="/recipes/"]')
        .filter({ hasText: fixture.recipe })
        .count(),
      0,
    );
    await page.goto(urlAt(base, "/retail/library"));
    await page.getByRole("heading", { name: "Library", exact: true }).waitFor();
    await page.getByText(/Hidden · Pinned/).waitFor();
    await capture(page, output, "library", 1440);
    await capture(page, output, "library", 760);
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.getByRole("button", { name: "Reveal", exact: true }).click();
    await page.getByRole("button", { name: "Unpin", exact: true }).click();
    await page.getByText("No pins or hidden items.").waitFor();
    await page.goto(comparisonUrl);
    await comparison(page, "2", "1");

    mark(
      "explicitly save, reopen, edit without saving, fork, then save revisions",
    );
    const name = `C12 browser ${Date.now()}`;
    const copyName = `${name} copy`;
    await page
      .getByRole("button", { name: "Save this investigation", exact: true })
      .click();
    await page.getByRole("textbox", { name: "Investigation name" }).fill(name);
    await page.getByRole("button", { name: "Save investigation" }).click();
    await page.waitForURL(
      (value) =>
        value.searchParams.has("saved") && value.searchParams.has("revision"),
    );
    const savedUrl = new URL(page.url());
    const originalId = savedUrl.searchParams.get("saved");
    assert.equal(savedUrl.searchParams.get("revision"), "1");
    await page.goto(urlAt(base, "/retail/library"));
    await page.getByRole("link", { name, exact: true }).click();
    await page.waitForURL(
      (value) =>
        value.pathname === recipeUrl.pathname &&
        value.searchParams.get("saved") === originalId,
    );
    await comparison(page, "2", "1");
    const copiedUrl = page.url();
    await page.reload();
    await comparison(page, "2", "1");
    const secondTab = await context.newPage();
    await secondTab.clock.setFixedTime(asOf);
    attachDiagnostics(secondTab, base, diagnostics);
    await secondTab.goto(copiedUrl);
    await comparison(secondTab, "2", "1");
    await secondTab.goto(urlAt(base, "/forever/activity?period=all"));
    await attempts(secondTab, "1");
    assert.equal(
      page.url(),
      copiedUrl,
      "Changing game in another tab must not change this tab's URL.",
    );
    await secondTab.waitForLoadState("networkidle");
    await secondTab.close();
    const independent = await browser.newContext({
      viewport: { width: 760, height: 900 },
    });
    const freshTab = await independent.newPage();
    await freshTab.clock.setFixedTime(asOf);
    attachDiagnostics(freshTab, base, diagnostics);
    await freshTab.goto(copiedUrl);
    await comparison(freshTab, "2", "1");
    await freshTab.waitForLoadState("networkidle");
    await independent.close();

    await page
      .getByRole("button", { name: "Save / update investigation", exact: true })
      .click();
    await page
      .getByRole("textbox", { name: "Investigation name" })
      .fill(copyName);
    await page.getByRole("button", { name: "Save as copy" }).click();
    await page.waitForURL(
      (value) =>
        value.searchParams.get("saved") !== originalId &&
        value.searchParams.has("saved"),
    );
    const copyId = new URL(page.url()).searchParams.get("saved");
    assert.equal(new URL(page.url()).searchParams.get("revision"), "1");
    await select(page, "Period", "All history");
    await route(page, recipeUrl.pathname, {
      period: "all",
      saved: copyId,
      revision: "1",
      bperiod: "fixed",
    });
    const beforeSave = await json(
      await fetch(urlAt(base, `/api/v1/saved-investigations/${copyId}`), {
        headers: { Origin: base.origin, "X-Artisan-Logbook-Client": "web" },
      }),
      "Unchanged saved definition",
    );
    assert.equal(
      beforeSave.revision,
      1,
      "Editing a scope must not implicitly save.",
    );
    assert.equal(beforeSave.definition.scope.period, "30");
    await page
      .getByRole("button", { name: "Save / update investigation", exact: true })
      .click();
    await page.getByRole("button", { name: "Save changes" }).click();
    await page.waitForURL(
      (value) => value.searchParams.get("revision") === "2",
    );
    await page.reload();
    await route(page, recipeUrl.pathname, { period: "all", revision: "2" });
    await comparison(page, "2", "1");
    await page.goto(urlAt(base, "/retail/library"));
    await page.getByRole("link", { name, exact: true }).waitFor();
    await page.getByRole("link", { name: copyName, exact: true }).waitFor();
    await capture(page, output, "saved-library", 1440);
    for (const savedName of [copyName, name]) {
      const savedRow = page
        .getByRole("link", { name: savedName, exact: true })
        .locator("..");
      await savedRow
        .getByRole("button", { name: "Delete", exact: true })
        .click();
      await savedRow.getByRole("button", { name: "Confirm delete" }).click();
      await page
        .getByRole("link", { name: savedName, exact: true })
        .waitFor({ state: "detached" });
    }
    await page.getByText("No saved investigations yet.").waitFor();

    mark(
      "Forever keeps overlapping IDs separate and labels unsupported metrics",
    );
    await page.goto(urlAt(base, "/forever/activity?period=all"));
    await attempts(page, "1");
    await page
      .getByRole("heading", { name: "Attributed schematic requirements" })
      .waitFor();
    await page.getByRole("button", { name: "More filters" }).click();
    assert.equal(
      await page.getByRole("combobox", { name: "Got back reagent" }).count(),
      0,
    );
    assert.equal(
      await page.getByRole("textbox", { name: "Buff active" }).count(),
      0,
    );
    assert.equal(
      await page.getByRole("heading", { name: "Returned materials" }).count(),
      0,
    );
    await page
      .getByRole("main")
      .getByRole("link", { name: fixture.recipe, exact: true })
      .first()
      .click();
    await route(
      page,
      `/forever/recipes/${encodeURIComponent(ids.otherRecipeId)}`,
      { period: "all" },
    );
    await page
      .getByRole("heading", { name: fixture.recipe, exact: true })
      .waitFor();
    await capture(page, output, "forever-recipe", 1440);
    await capture(page, output, "forever-recipe", 760);
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.getByRole("tab", { name: "Reagents", exact: true }).click();
    await page
      .getByRole("main")
      .getByRole("link", { name: fixture.input, exact: true })
      .first()
      .click();
    await page
      .getByRole("heading", { name: "Attributed schematic requirements" })
      .waitFor();
    await page
      .getByText(
        /Inputs are attributed schematic requirements, not measured consumption/,
      )
      .waitFor();
    assert.equal(
      await page.getByRole("heading", { name: "Recorded returns" }).count(),
      0,
    );
    await capture(page, output, "forever-item", 760);

    mark("global Companion management retains the analytical context");
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(urlAt(base, "/companion"));
    await page.getByRole("heading", { name: "Import history" }).waitFor();
    await page
      .getByText("No import has happened in this Companion session.")
      .waitFor();
    await page.getByText("Investigating Forever").waitFor();
    await capture(page, output, "companion", 1440);
    await capture(page, output, "companion", 760);
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.getByRole("button", { name: "Import now" }).click();
    await page
      .getByText("Import accepted. Follow its outcome below.")
      .waitFor();
    await page.getByText("Successful", { exact: true }).waitFor({
      timeout: 45_000,
    });
    await page.getByRole("button", { name: /Manual import/ }).click();
    const receipt = page.getByRole("row").filter({
      hasText: "No change",
    });
    await receipt.getByText("Successful · No change").waitFor();
    assert.equal(
      (await receipt.getByRole("cell").nth(2).innerText()).trim(),
      "4",
    );
    await receipt.getByText("Retail, Forever").waitFor();

    assert.deepEqual(diagnostics.pageErrors, [], "Uncaught browser errors");
    assert.deepEqual(
      diagnostics.networkErrors,
      [],
      "Backend/API requests must succeed",
    );
    assert.deepEqual(
      diagnostics.remoteRequests,
      [],
      "The app must not load remote dependencies",
    );
    console.log("C12 browser acceptance passed.");
  } catch (error) {
    diagnostics.failure = `${step}: ${error.stack ?? error}`;
    await page
      .screenshot({ path: path.join(output, "failure.png"), fullPage: true })
      .catch(() => {});
    throw error;
  } finally {
    await writeFile(
      path.join(output, "diagnostics.json"),
      `${JSON.stringify(diagnostics, null, 2)}\n`,
    );
    await browser.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  assert(
    process.argv.length === 4,
    "Usage: node scripts/c12-browser.mjs http://127.0.0.1:5173 .artifacts/c12-browser",
  );
  const base = new URL(process.argv[2]);
  assert.equal(base.protocol, "http:");
  assert(
    ["127.0.0.1", "localhost"].includes(base.hostname),
    "Only a loopback, isolated Companion is permitted.",
  );
  assert.equal(base.pathname, "/");
  const output = path.resolve(process.argv[3]);
  assert(
    !/^\/(?:tmp|var\/tmp)(?:\/|$)/.test(output),
    "Do not write screenshots to temporary directories.",
  );
  await run(base, output);
}
