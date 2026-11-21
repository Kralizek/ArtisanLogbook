import { MantineProvider } from "@mantine/core";
import { render, screen, within } from "@testing-library/react";
import type { ReactNode } from "react";
import { expect, it } from "vitest";
import { LogbookTable } from "./LogbookTable";
import { craftHighlights, type LogbookCraft } from "./logbookHighlights";

function craft(overrides: Partial<LogbookCraft> = {}): LogbookCraft {
  return {
    id: "craft-1",
    recordedAt: "2026-11-21T13:37:00Z",
    character: { id: "c", name: "Kralizek", classFile: "MAGE" },
    recipe: { id: "r", blizzardId: 1230869, name: "Light's Potential" },
    profession: { id: "p", name: "Alchemy" },
    outputsComplete: true,
    inputsComplete: true,
    concentrationSpent: null,
    multicraftBonus: null,
    hasIngenuityProc: null,
    appliedIngenuityRefund: null,
    reagents: null,
    outputs: [
      {
        item: { id: "i", name: "Light's Potential", blizzardId: 241308 },
        quality: 2,
        quantityExact: "5",
      },
    ],
    ...overrides,
  } as LogbookCraft;
}

const linkTo = (destination: string, children: ReactNode) => (
  <a href={`/${destination}`}>{children}</a>
);

function renderTable(crafts: LogbookCraft[], showRecipe = true) {
  render(
    <MantineProvider>
      <LogbookTable
        crafts={crafts}
        showRecipe={showRecipe}
        highlights
        linkTo={linkTo}
      />
    </MantineProvider>,
  );
}

it("lays out columns like the addon logbook", () => {
  renderTable([craft()]);
  expect(
    screen.getAllByRole("columnheader").map((cell) => cell.textContent),
  ).toEqual([
    "Recipe",
    "Result",
    "Character",
    "Profession",
    "Qty",
    "Highlights",
    "Time",
  ]);
  const row = screen.getAllByRole("row")[1];
  expect(within(row).getByText("Quality 2")).toBeInTheDocument();
  expect(within(row).getByText(", Mage")).toBeInTheDocument();
  expect(row.querySelector("a time")).toHaveAttribute(
    "dateTime",
    "2026-11-21T13:37:00Z",
  );
});

it("omits recipe and profession inside a recipe's own history", () => {
  renderTable([craft()], false);
  expect(screen.queryByRole("columnheader", { name: "Recipe" })).toBeNull();
  expect(screen.queryByRole("columnheader", { name: "Profession" })).toBeNull();
});

it("highlights only recorded positive outcomes", () => {
  expect(craftHighlights(craft())).toEqual([]);
  expect(
    craftHighlights(
      craft({
        concentrationSpent: 40,
        multicraftBonus: 3,
        hasIngenuityProc: true,
        appliedIngenuityRefund: 20,
        reagents: [
          { returnedQuantityExact: "2" },
          { returnedQuantityExact: "1" },
          { returnedQuantityExact: null },
        ],
      }),
    ).map((highlight) => highlight.label),
  ).toEqual([
    "Concentration 40",
    "Multicraft +3",
    "Ingenuity +20",
    "Resourcefulness 3",
  ]);
  expect(
    craftHighlights(craft({ hasIngenuityProc: false, concentrationSpent: 0 })),
  ).toEqual([]);
});

it("totals outputs and marks a partial or unrecorded quantity", () => {
  renderTable([
    craft({
      id: "several",
      outputsComplete: false,
      outputs: [
        {
          item: { id: "a", name: "Alpha", blizzardId: 1 },
          quality: null,
          quantityExact: "2",
        },
        {
          item: { id: "b", name: null, blizzardId: 2 },
          quality: null,
          quantityExact: "3",
        },
      ],
    }),
    craft({ id: "unrecorded", outputs: null }),
  ]);
  const [, several, unrecorded] = screen.getAllByRole("row");
  expect(
    within(several).getByLabelText(
      "5, partial: some outputs were not recorded",
    ),
  ).toBeInTheDocument();
  expect(within(several).getByText("Item 2")).toBeInTheDocument();
  expect(within(several).getByText("× 3")).toBeInTheDocument();
  expect(within(unrecorded).getByText("Not recorded")).toBeInTheDocument();
  expect(
    within(unrecorded).getByLabelText("Quantity not recorded"),
  ).toBeInTheDocument();
});
