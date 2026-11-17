import { expect, it } from "vitest";
import {
  exact,
  itemLabel,
  measuredCraftAverage,
  observedRateDifference,
  outcomeRows,
  rate,
  rawQuantity,
} from "./analysisFormat";

it("preserves exact large analytical quantities and refuses imprecise raw observations", () => {
  expect(exact("90071992547409930.125")).toBe("90,071,992,547,409,930.125");
  expect(exact("1.000000000000000000000000000000")).toBe("1");
  expect(exact("0.000000000000000000000000000100")).toBe(
    "0.0000000000000000000000000001",
  );
  expect(rawQuantity(Number.MAX_SAFE_INTEGER + 2)).toBe(
    "Exceeds exact browser precision",
  );
  expect(rawQuantity(0.125)).toBe(
    "Exact decimal precision unavailable in browser",
  );
  expect(rawQuantity(null)).toBe("Unknown");
});

it("normalizes only fully complete populations using exact decimal arithmetic", () => {
  expect(
    measuredCraftAverage({
      attempts: "3",
      measuredAttempts: "3",
      incompleteAttempts: "0",
      quantity: "90071992547409930.125",
    }),
  ).toBe(
    "≈ 30,023,997,515,803,310.041667 per measured craft (exact ratio: 90,071,992,547,409,930.125 ÷ 3)",
  );
  expect(
    measuredCraftAverage({
      attempts: "4",
      measuredAttempts: "4",
      incompleteAttempts: "0",
      quantity: "1.25",
    }),
  ).toBe("0.3125 per measured craft");
  expect(
    measuredCraftAverage({
      attempts: "3",
      measuredAttempts: "2",
      incompleteAttempts: "1",
      quantity: "12",
    }),
  ).toMatch(/unavailable: incomplete/);
  expect(
    measuredCraftAverage({
      attempts: "3",
      measuredAttempts: "0",
      incompleteAttempts: "0",
      quantity: null,
    }),
  ).toBe("Per-craft average not measured");
  expect(
    measuredCraftAverage({
      attempts: "2",
      measuredAttempts: "2",
      incompleteAttempts: "0",
      quantity: "0.0000000000000000000000000001",
    }),
  ).toContain("exact ratio: 0.0000000000000000000000000001 ÷ 2");
});

it("compares observed rates as exact rational differences, not all-attempt rates", () => {
  expect(
    observedRateDifference(
      {
        observedAttempts: "10000000000000000",
        positiveAttempts: "2500000000000000",
      },
      {
        observedAttempts: "10000000000000000",
        positiveAttempts: "5000000000000000",
      },
    ),
  ).toBe("B − A observed rate: +25.0 percentage points");
  expect(
    observedRateDifference(
      { observedAttempts: "3", positiveAttempts: "2" },
      { observedAttempts: "3", positiveAttempts: "1" },
    ),
  ).toBe("B − A observed rate: −33.3 percentage points");
  expect(
    observedRateDifference(
      { observedAttempts: "10000", positiveAttempts: "1" },
      { observedAttempts: "10000", positiveAttempts: "2" },
    ),
  ).toBe("B − A observed rate: +<0.1 percentage points");
  expect(
    observedRateDifference(
      { observedAttempts: "0", positiveAttempts: "0" },
      { observedAttempts: "2", positiveAttempts: "1" },
    ),
  ).toBeNull();
});

it("normalizes using only observed attempts, retaining unknown and unsupported outcomes", () => {
  expect(
    rate({
      observedAttempts: "10000000000000000",
      positiveAttempts: "2500000000000000",
      unknownAttempts: "50",
    }),
  ).toBe("25.0% of observed attempts");
  expect(
    rate({
      observedAttempts: "10000",
      positiveAttempts: "1",
      unknownAttempts: "0",
    }),
  ).toBe("<0.1% of observed attempts");
  expect(
    rate({
      observedAttempts: "0",
      positiveAttempts: "0",
      unknownAttempts: "9",
    }),
  ).toBeUndefined();
  const rows = outcomeRows("9", {
    production: {
      attempts: "9",
      measuredAttempts: "2",
      incompleteAttempts: "7",
      quantity: null,
    },
    ingenuity: {
      observedAttempts: "3",
      positiveAttempts: "1",
      unknownAttempts: "4",
      total: "1",
    },
    resourcefulness: null,
    multicraft: null,
    concentration: {
      observedAttempts: "9",
      positiveAttempts: "4",
      unknownAttempts: "0",
      total: "520",
    },
    refund: null,
  });
  expect(rows).toHaveLength(3);
  expect(rows[0].value).toBe("Not measured");
  expect(rows[0].coverage).toContain("7 incomplete");
  expect(rows[1].value).toBe("1 proc");
  expect(rows[1].coverage).toBe(
    "3 observed of 9 attempts · 2 without Concentration · 4 unknown",
  );
  expect(rows[2].value).toBe("4 attempts used · 520 spent");
  expect(
    outcomeRows(
      "9",
      {
        production: {
          attempts: "9",
          measuredAttempts: "2",
          incompleteAttempts: "7",
          quantity: null,
        },
        ingenuity: {
          observedAttempts: "3",
          positiveAttempts: "1",
          unknownAttempts: "6",
          total: "1",
        },
      },
      false,
    ),
  ).toHaveLength(1);
});

it("keeps same-named item quality variants distinguishable", () => {
  const bloom = { name: "Tranquility Bloom", blizzardId: 236761 };
  expect(itemLabel({ ...bloom, quality: 1 })).toBe(
    "Tranquility Bloom · Quality 1 · #236761",
  );
  expect(itemLabel({ ...bloom, quality: null })).toBe(
    "Tranquility Bloom · #236761",
  );
});
