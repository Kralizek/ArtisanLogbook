import { expect, it } from "vitest";
import { investigationLink, periodBounds } from "./scope";

const game = {
  canonicalId: "1",
  routeAlias: "retail",
  displayName: "Retail",
  project: 1,
  progressionTrack: null,
};
it("inherits exploration without changing its originating scope or saved identity", () => {
  const overview = new URLSearchParams("period=90&character=opaque");
  const recipe = new URLSearchParams(overview);
  recipe.set("period", "30");
  recipe.set("saved", "original");
  recipe.set("after", "cursor");
  expect(
    investigationLink(game, "items/opaque", recipe, { recipe: "recipe-id" }),
  ).toBe("/retail/items/opaque?period=30&character=opaque&recipe=recipe-id");
  expect(overview.toString()).toBe("period=90&character=opaque");
});
it("evaluates independent relative comparison periods and preserves fixed dates", () => {
  const params = new URLSearchParams(
    "period=30&bperiod=fixed&bfrom=2025-01-01&bto=2025-02-01",
  );
  const now = new Date("2026-11-15T12:00:00Z");
  expect(periodBounds(params, "", now).from).toBe("2026-10-16T12:00:00.000Z");
  expect(periodBounds(params, "b", now)).toEqual({
    from: "2025-01-01T00:00:00.0000000Z",
    to: "2025-02-01T23:59:59.9999999Z",
  });
  expect(() =>
    periodBounds(
      new URLSearchParams("period=fixed&from=2025-02-01&to=2025-01-01"),
    ),
  ).toThrow("valid");
  expect(() =>
    periodBounds(
      new URLSearchParams("period=fixed&from=2025-02-30&to=2025-03-30"),
    ),
  ).toThrow("valid");
});
