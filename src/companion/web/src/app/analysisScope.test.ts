import { describe, expect, it } from "vitest";
import { analysisFilter, roleFilter, roleLinkParams } from "./analysisScope";

describe("investigation filters", () => {
  it("keeps recipe and comparison populations independent while retaining recorded absence filters", () => {
    const params = new URLSearchParams(
      "period=all&recipe=old&character=a&configuration=one&compare=1&bperiod=all&bcharacter=b&bconfiguration=two&babsentBuff=123&bfinishing=opaque",
    );
    expect(analysisFilter(params, "", "recipe")).toEqual({
      recipeId: "recipe",
      characterId: "a",
      configurationId: "one",
    });
    expect(analysisFilter(params, "b", "recipe")).toEqual({
      recipeId: "recipe",
      characterId: "b",
      configurationId: "two",
      absentBuffSpellId: 123,
      finishingItemId: "opaque",
    });
  });

  it("keeps output, gross commitment and returns as separate item populations and drill-down scopes", () => {
    const params = new URLSearchParams(
      "period=all&recipe=r&input=other&output=another&returned=third&item=any&character=c&saved=entry&revision=1",
    );
    expect(roleFilter(params, "item", "output")).toEqual({
      recipeId: "r",
      characterId: "c",
      outputItemId: "item",
    });
    expect(roleFilter(params, "item", "input")).toEqual({
      recipeId: "r",
      characterId: "c",
      inputItemId: "item",
    });
    const link = roleLinkParams(params, "item", "returned");
    expect(link.get("returned")).toBe("item");
    expect(link.has("input")).toBe(false);
    expect(link.get("character")).toBe("c");
  });

  it("rejects invalid recorded spell filters before issuing a query", () => {
    expect(() =>
      analysisFilter(new URLSearchParams("period=all&buff=-1")),
    ).toThrow(/spell ID/);
    expect(() =>
      analysisFilter(new URLSearchParams("period=all&buff=2147483648")),
    ).toThrow(/spell ID/);
  });
});
