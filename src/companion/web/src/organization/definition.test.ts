import { describe, expect, it } from "vitest";
import {
  definitionFromLocation,
  definitionUrl,
  parseDefinition,
} from "./definition";

const id = "550e8400-e29b-41d4-a716-446655440000";

describe("executable saved investigations", () => {
  it("round-trips an independently scoped comparison without resolving relative periods", () => {
    const definition = definitionFromLocation(
      "/retail/recipes/opaque%3Arecipe",
      "?period=90&character=opaque-a&input=opaque-input&configuration=setup-a&granularity=week&compare=1&bperiod=fixed&bfrom=2025-01-01&bto=2025-01-31&bcharacter=opaque-b&binput=opaque-other&saved=" +
        id +
        "&revision=4",
      "retail",
    );
    expect(definition).toEqual({
      destination: "recipe",
      entity: "opaque:recipe",
      scope: {
        period: "90",
        character: "opaque-a",
        input: "opaque-input",
        configuration: "setup-a",
      },
      query: {
        granularity: "week",
        compare: {
          period: "fixed",
          from: "2025-01-01",
          to: "2025-01-31",
          character: "opaque-b",
          input: "opaque-other",
        },
      },
    });
    const result = new URL(
      definitionUrl(definition, "retail", { id, revision: 4 }),
      "http://local",
    );
    expect(
      definitionFromLocation(result.pathname, result.search, "retail"),
    ).toEqual(definition);
    expect(result.searchParams.get("saved")).toBe(id);
    expect(result.searchParams.get("revision")).toBe("4");
    expect(definitionUrl(definition, "retail")).not.toContain("saved=");
  });

  it("round-trips recorded buff spell IDs and opaque finishing items in both populations", () => {
    const definition = definitionFromLocation(
      "/retail/recipes/opaque%3Arecipe",
      "?period=90&buff=123&absentBuff=456&finishing=opaque%3Aitem-a&absentFinishing=opaque%3Aitem-b&compare=1&bperiod=30&bbuff=789&babsentBuff=1011&bfinishing=opaque%3Aitem-c&babsentFinishing=opaque%3Aitem-d",
      "retail",
    );
    expect(definition.scope).toMatchObject({
      buff: "123",
      absentBuff: "456",
      finishing: "opaque:item-a",
      absentFinishing: "opaque:item-b",
    });
    expect(definition.query.compare).toMatchObject({
      buff: "789",
      absentBuff: "1011",
      finishing: "opaque:item-c",
      absentFinishing: "opaque:item-d",
    });
    const url = new URL(definitionUrl(definition, "retail"), "http://local");
    expect(definitionFromLocation(url.pathname, url.search, "retail")).toEqual(
      definition,
    );
    expect(
      definitionFromLocation("/retail/activity", "?buff=123", "retail").scope
        .buff,
    ).toBe("123");
  });

  it.each([
    "?period=30&period=90",
    "?period=30&unrecognized=secret",
    "?period=30&bperiod=90",
    "?period=30&compare=0",
    "?period=30&compare=1",
    "?period=fixed&from=2025-02-01&to=2025-01-01",
    "?period=fixed&from=2025-02-30&to=2025-03-01",
    "?period=30&from=2025-01-01",
    "?period=30&configuration=",
    "?period=90&buff=0",
    "?period=90&buff=-1",
    "?period=90&buff=01",
    "?period=90&buff=1.5",
    "?period=90&buff=9007199254740992",
    "?period=90&absentBuff=not-a-spell",
    "?period=90&finishing=",
    "?period=90&babsentFinishing=opaque-item",
    "?period=90&compare=1&bperiod=30&babsentBuff=0",
    "?saved=" + id,
    "?saved=" + id + "&revision=0",
  ])("rejects malformed or silently broadening URL %s", (search) => {
    expect(() =>
      definitionFromLocation("/retail/activity", search, "retail"),
    ).toThrow();
  });

  it("rejects unknown, context-bearing and version-skewed documents before execution", () => {
    const valid = {
      destination: "activity",
      scope: { period: "all" },
      query: {},
    };
    expect(parseDefinition(valid)).toEqual(valid);
    expect(() => parseDefinition({ ...valid, context: "1" })).toThrow();
    expect(() =>
      parseDefinition({ ...valid, scope: { period: "30", unknown: "x" } }),
    ).toThrow();
    expect(() => parseDefinition({ ...valid, scope: {} })).toThrow();
    expect(() => parseDefinition({ ...valid, entity: "" })).toThrow();
    expect(() =>
      parseDefinition({ ...valid, scope: { period: "all", buff: 123 } }),
    ).toThrow();
    expect(() =>
      parseDefinition({
        ...valid,
        scope: { period: "all", absentBuff: "9007199254740992" },
      }),
    ).toThrow();
    expect(() => parseDefinition(valid, 2)).toThrow();
    expect(() =>
      parseDefinition({ ...valid, query: { compare: { period: "fixed" } } }),
    ).toThrow();
  });
});
