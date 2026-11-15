import { MantineProvider } from "@mantine/core";
import { render, screen, within } from "@testing-library/react";
import { expect, it } from "vitest";
import { CharacterComparison } from "./CharacterComparison";

it("compares observed changes for each matched character, not just absolute rates", () => {
  const character = (id: string, positive: string) => {
    const measure = {
      attempts: "100",
      measuredAttempts: "100",
      incompleteAttempts: "0",
      quantity: "100",
    };
    return {
      id,
      name: id,
      measure,
      metrics: {
        production: measure,
        ingenuity: {
          observedAttempts: "100",
          positiveAttempts: positive,
          unknownAttempts: "0",
          total: null,
        },
      },
    };
  };
  render(
    <MantineProvider>
      <CharacterComparison
        left={{
          truncated: false,
          nodes: [character("A", "18"), character("B", "24")],
        }}
        right={{
          truncated: false,
          nodes: [
            character("A", "28"),
            character("B", "30"),
            character("C", "10"),
          ],
        }}
      />
    </MantineProvider>,
  );
  const rowA = screen.getByRole("row", { name: /^A / });
  const rowB = screen.getByRole("row", { name: /^B / });
  expect(within(rowA).getByText(/18.0%/)).toBeInTheDocument();
  expect(within(rowA).getByText(/28.0%/)).toBeInTheDocument();
  expect(within(rowA).getByText(/10.0 percentage points/)).toBeInTheDocument();
  expect(within(rowB).getByText(/30.0%/)).toBeInTheDocument();
  expect(within(rowB).getByText(/6.0 percentage points/)).toBeInTheDocument();
  expect(
    within(screen.getByRole("row", { name: /^C / })).getByText(
      "Insufficient observed evidence",
    ),
  ).toBeInTheDocument();
});
