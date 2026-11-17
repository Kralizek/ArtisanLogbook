import { MantineProvider } from "@mantine/core";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it, vi } from "vitest";
import {
  ItemTooltipDocument,
  RecipeTooltipDocument,
} from "../graphql/generated/graphql";
import { ItemTooltip, RecipeTooltip } from "./EntityTooltip";

const query = vi.hoisted(() => vi.fn());
vi.mock("@apollo/client/react", () => ({ useQuery: query }));

const item = (blizzardId: number, quality: number | null) => ({
  id: `item-${blizzardId}`,
  blizzardId,
  name: "Tranquility Bloom",
  quality,
});

beforeEach(() => {
  query.mockReset();
  query.mockImplementation((document: unknown) => {
    if (document === ItemTooltipDocument)
      return { data: { contextItem: item(236767, 2) }, loading: false };
    if (document === RecipeTooltipDocument)
      return {
        loading: false,
        data: {
          contextRecipe: {
            id: "recipe-1",
            blizzardId: 1230858,
            name: "Light's Potential",
            maxQuality: 2,
            profession: { id: "p", name: "Alchemy" },
            expansion: { id: "e", name: "Midnight" },
            reagentSlots: [
              {
                id: "s1",
                reagentType: "BASIC",
                isRequired: true,
                requiredQuantity: 3,
                candidateItems: [item(236761, 1), item(236767, 2)],
              },
              {
                id: "s2",
                reagentType: "FINISHING",
                isRequired: false,
                requiredQuantity: 1,
                candidateItems: [
                  { id: "f", blizzardId: 9, name: "Catalyst", quality: null },
                ],
              },
            ],
          },
        },
      };
    throw new Error("Unexpected query");
  });
});

function renderWithin(children: React.ReactNode) {
  return render(<MantineProvider env="test">{children}</MantineProvider>);
}

it("loads item details only when focus opens the tooltip and shows the reagent quality", async () => {
  const user = userEvent.setup();
  renderWithin(
    <ItemTooltip game={{ canonicalId: "1" }} id="item-236767">
      <a href="#item">Tranquility Bloom</a>
    </ItemTooltip>,
  );
  expect(query).not.toHaveBeenCalled();
  await user.tab();
  expect(await screen.findByText("Quality 2")).toBeInTheDocument();
  expect(screen.getByText("Item #236767")).toBeInTheDocument();
  expect(query).toHaveBeenCalledWith(ItemTooltipDocument, {
    variables: { context: "1", id: "item-236767" },
  });
});

it("summarizes recipe reagents and merges same-named quality variants", async () => {
  const user = userEvent.setup();
  renderWithin(
    <RecipeTooltip game={{ canonicalId: "1" }} id="recipe-1">
      <a href="#recipe">Light's Potential</a>
    </RecipeTooltip>,
  );
  await user.hover(screen.getByRole("link", { name: "Light's Potential" }));
  expect(
    await screen.findByText("3 × Tranquility Bloom (Quality 1/2)"),
  ).toBeInTheDocument();
  expect(screen.getByText("Alchemy · Midnight")).toBeInTheDocument();
  expect(screen.getByText("Finishing")).toBeInTheDocument();
  expect(screen.getByText("1 × Catalyst")).toBeInTheDocument();
});
