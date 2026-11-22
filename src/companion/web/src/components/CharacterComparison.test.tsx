import { MantineProvider } from "@mantine/core";
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState, type ComponentProps } from "react";
import { expect, it, vi } from "vitest";
import { CharacterComparison as Comparison } from "./CharacterComparison";

function CharacterComparison(
  props: Omit<ComponentProps<typeof Comparison>, "metric" | "onMetricChange">,
) {
  const [metric, setMetric] = useState<
    ComponentProps<typeof Comparison>["metric"]
  >(props.includeRetailOutcomes === false ? "production" : "ingenuity");
  return <Comparison {...props} metric={metric} onMetricChange={setMetric} />;
}

const extraOutcomes = {
  resourcefulness: null,
  multicraft: null,
  concentration: null,
  refund: null,
};

it("compares observed changes for each matched character, not just absolute rates", () => {
  const character = (id: string, positive: string, allocated?: string) => {
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
      resourceAllocation: { ...measure, quantity: allocated ?? "0" },
      metrics: {
        ...extraOutcomes,
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
    <MantineProvider env="test">
      <CharacterComparison
        left={{
          truncated: false,
          nodes: [character("A", "18"), character("B", "24")],
        }}
        right={{
          truncated: false,
          nodes: [
            character("A", "28", "200"),
            character("B", "30", "300"),
            character("C", "10"),
          ],
        }}
        resourceComparison
      />
    </MantineProvider>,
  );
  const rowA = screen.getByRole("row", { name: /^A / });
  const rowB = screen.getByRole("row", { name: /^B / });
  expect(within(rowA).getByText(/18.0%/)).toBeInTheDocument();
  expect(within(rowA).getByText(/28.0%/)).toBeInTheDocument();
  expect(within(rowA).getByText(/10.0 percentage points/)).toBeInTheDocument();
  expect(
    within(rowA).getByText(/\+5.00 percentage points per allocated unit/),
  ).toBeInTheDocument();
  expect(within(rowB).getByText(/30.0%/)).toBeInTheDocument();
  expect(within(rowB).getByText(/6.0 percentage points/)).toBeInTheDocument();
  expect(
    within(rowB).getByText(/\+2.00 percentage points per allocated unit/),
  ).toBeInTheDocument();
  expect(
    within(screen.getByRole("row", { name: /^C / })).getByText(
      "Insufficient observed evidence",
    ),
  ).toBeInTheDocument();
});

it("compares other proc rates and output per craft, including resource-normalized differences", async () => {
  Element.prototype.scrollIntoView = vi.fn();
  const character = (
    id: string,
    positive: string,
    output: string,
    allocation: string,
    observed = "100",
  ) => {
    const measure = {
      attempts: "100",
      measuredAttempts: "100",
      incompleteAttempts: "0",
      quantity: output,
    };
    const outcome = {
      observedAttempts: observed,
      positiveAttempts: positive,
      unknownAttempts: observed === "100" ? "0" : "1",
      total: null,
    };
    return {
      id,
      name: id,
      measure,
      resourceAllocation: { ...measure, quantity: allocation },
      metrics: {
        ...extraOutcomes,
        production: measure,
        ingenuity: outcome,
        resourcefulness: outcome,
      },
    };
  };
  render(
    <MantineProvider env="test">
      <CharacterComparison
        left={{
          truncated: false,
          nodes: [
            character("A", "10", "200", "0"),
            character("B", "30", "200", "0"),
          ],
        }}
        right={{
          truncated: false,
          nodes: [
            character("A", "30", "300", "200"),
            character("B", "40", "250", "400", "99"),
          ],
        }}
        resourceComparison
      />
    </MantineProvider>,
  );
  const user = userEvent.setup();
  await user.click(
    screen.getByRole("combobox", { name: "Outcome to compare" }),
  );
  await user.click(
    await screen.findByRole("option", { name: "Resourcefulness proc rate" }),
  );
  const rowA = screen.getByRole("row", { name: /^A / });
  const rowB = screen.getByRole("row", { name: /^B / });
  expect(within(rowA).getByText(/20.0 percentage points/)).toBeInTheDocument();
  expect(
    within(rowA).getByText(/\+10.00 percentage points per allocated unit/),
  ).toBeInTheDocument();
  expect(
    within(rowB).getByText("Insufficient complete evidence"),
  ).toBeInTheDocument();
  await user.click(
    screen.getByRole("combobox", { name: "Outcome to compare" }),
  );
  await user.click(
    await screen.findByRole("option", { name: "Actual output per craft" }),
  );
  expect(
    within(rowA).getByText(/B − A: \+1.00 output units per measured craft/),
  ).toBeInTheDocument();
  expect(
    within(rowA).getByText(/\+0.50 output units per allocated unit/),
  ).toBeInTheDocument();
  expect(
    within(rowB).getByText(/≈ \+0.13 output units per allocated unit/),
  ).toBeInTheDocument();
});

it("compares production without exposing unsupported Retail outcomes", () => {
  const measure = {
    attempts: "1",
    measuredAttempts: "1",
    incompleteAttempts: "0",
    quantity: "3",
  };
  const character = {
    id: "A",
    name: "A",
    measure,
    resourceAllocation: null,
    metrics: { ...extraOutcomes, production: measure, ingenuity: null },
  };
  render(
    <MantineProvider>
      <CharacterComparison
        left={{
          nodes: [
            { ...character, resourceAllocation: { ...measure, quantity: "0" } },
          ],
          truncated: false,
        }}
        right={{
          nodes: [
            { ...character, resourceAllocation: { ...measure, quantity: "2" } },
          ],
          truncated: false,
        }}
        includeRetailOutcomes={false}
        attributedRequirements
        resourceComparison
      />
    </MantineProvider>,
  );
  expect(
    screen.getByDisplayValue("Actual output per craft"),
  ).toBeInTheDocument();
  expect(
    screen.getByText("B − A: 0.00 output units per measured craft"),
  ).toBeInTheDocument();
  expect(
    screen.getByText("Difference per attributed unit"),
  ).toBeInTheDocument();
  expect(
    screen.getByText(/0.00 output units per attributed unit/),
  ).toBeInTheDocument();
  expect(
    screen.getByText(/attributed schematic requirements per B craft/),
  ).toHaveTextContent("not measured consumption");
});

it("compares one returned material per craft and withholds incomplete evidence", async () => {
  Element.prototype.scrollIntoView = vi.fn();
  const measure = {
    attempts: "2",
    measuredAttempts: "2",
    incompleteAttempts: "0",
    quantity: "0",
  };
  const character = (id: string, allocation: string) => ({
    id,
    name: id,
    measure,
    resourceAllocation: { ...measure, quantity: allocation },
    metrics: { ...extraOutcomes, production: measure, ingenuity: null },
  });
  render(
    <MantineProvider env="test">
      <CharacterComparison
        left={{
          nodes: [character("A", "0"), character("B", "0")],
          truncated: false,
        }}
        right={{
          nodes: [character("A", "4"), character("B", "4")],
          truncated: false,
        }}
        leftReturns={{
          nodes: [
            { id: "A", returnedItem: { ...measure, quantity: "0.5" } },
            { id: "B", returnedItem: { ...measure, quantity: "0" } },
          ],
          truncated: false,
        }}
        rightReturns={{
          nodes: [
            { id: "A", returnedItem: { ...measure, quantity: "2.5" } },
            {
              id: "B",
              returnedItem: {
                ...measure,
                measuredAttempts: "1",
                incompleteAttempts: "1",
                quantity: "0.5",
              },
            },
          ],
          truncated: false,
        }}
        resourceComparison
      />
    </MantineProvider>,
  );
  const user = userEvent.setup();
  await user.click(
    screen.getByRole("combobox", { name: "Outcome to compare" }),
  );
  await user.click(
    await screen.findByRole("option", { name: "Returned material per craft" }),
  );
  const rowA = screen.getByRole("row", { name: /^A / });
  const rowB = screen.getByRole("row", { name: /^B / });
  expect(
    within(rowA).getByText(/B − A: \+1.00 returned units per measured craft/),
  ).toBeInTheDocument();
  expect(
    within(rowA).getByText(/\+0.50 returned units per allocated unit/),
  ).toBeInTheDocument();
  expect(
    within(rowB).getByText("Insufficient observed evidence"),
  ).toBeInTheDocument();
  expect(
    within(rowB).getByText("Insufficient complete evidence"),
  ).toBeInTheDocument();
});

it("does not compute a production improvement from incomplete output collections", () => {
  const measure = {
    attempts: "2",
    measuredAttempts: "1",
    incompleteAttempts: "1",
    quantity: "3",
  };
  const allocation = {
    attempts: "2",
    measuredAttempts: "2",
    incompleteAttempts: "0",
    quantity: "2",
  };
  const row = {
    id: "A",
    name: "A",
    measure,
    resourceAllocation: allocation,
    metrics: { ...extraOutcomes, production: measure, ingenuity: null },
  };
  render(
    <MantineProvider>
      <CharacterComparison
        left={{
          nodes: [
            { ...row, resourceAllocation: { ...allocation, quantity: "0" } },
          ],
          truncated: false,
        }}
        right={{ nodes: [row], truncated: false }}
        includeRetailOutcomes={false}
        resourceComparison
      />
    </MantineProvider>,
  );
  expect(
    screen.getByText("Insufficient observed evidence"),
  ).toBeInTheDocument();
  expect(
    screen.getByText("Insufficient complete evidence"),
  ).toBeInTheDocument();
});

it("withholds per-unit differences when allocation or proc observations are incomplete", () => {
  const measure = {
    attempts: "2",
    measuredAttempts: "2",
    incompleteAttempts: "0",
    quantity: "4",
  };
  const row = {
    id: "A",
    name: "A",
    measure,
    resourceAllocation: {
      ...measure,
      measuredAttempts: "1",
      incompleteAttempts: "1",
    },
    metrics: {
      ...extraOutcomes,
      production: measure,
      ingenuity: {
        observedAttempts: "2",
        positiveAttempts: "1",
        unknownAttempts: "0",
        total: null,
      },
    },
  };
  render(
    <MantineProvider>
      <CharacterComparison
        left={{
          truncated: false,
          nodes: [
            { ...row, resourceAllocation: { ...measure, quantity: "0" } },
          ],
        }}
        right={{ truncated: false, nodes: [row] }}
        resourceComparison
      />
    </MantineProvider>,
  );
  expect(
    screen.getByText("Insufficient complete evidence"),
  ).toBeInTheDocument();
});

it.each([
  ["missing allocation", null, "2", "1"],
  [
    "unknown quantity",
    {
      attempts: "2",
      measuredAttempts: "2",
      incompleteAttempts: "0",
      quantity: null,
    },
    "2",
    "1",
  ],
  [
    "zero quantity",
    {
      attempts: "2",
      measuredAttempts: "2",
      incompleteAttempts: "0",
      quantity: "0",
    },
    "2",
    "1",
  ],
  [
    "partial proc observations",
    {
      attempts: "2",
      measuredAttempts: "2",
      incompleteAttempts: "0",
      quantity: "4",
    },
    "1",
    "1",
  ],
])(
  "withholds normalization for %s",
  (_label, allocation, observed, positive) => {
    const measure = {
      attempts: "2",
      measuredAttempts: "2",
      incompleteAttempts: "0",
      quantity: "2",
    };
    const row = {
      id: "A",
      name: "A",
      measure,
      resourceAllocation: allocation,
      metrics: {
        ...extraOutcomes,
        production: measure,
        ingenuity: {
          observedAttempts: observed,
          positiveAttempts: positive,
          unknownAttempts: "0",
          total: null,
        },
      },
    };
    render(
      <MantineProvider>
        <CharacterComparison
          left={{
            truncated: false,
            nodes: [
              { ...row, resourceAllocation: { ...measure, quantity: "0" } },
            ],
          }}
          right={{ truncated: false, nodes: [row] }}
          resourceComparison
        />
      </MantineProvider>,
    );
    expect(
      screen.getByText("Insufficient complete evidence"),
    ).toBeInTheDocument();
  },
);

it("normalizes a negative difference without losing large integer precision", () => {
  const measure = {
    attempts: "2",
    measuredAttempts: "2",
    incompleteAttempts: "0",
    quantity: "2",
  };
  const row = (positive: string) => ({
    id: "A",
    name: "A",
    measure,
    resourceAllocation: { ...measure, quantity: "9007199254740993" },
    metrics: {
      ...extraOutcomes,
      production: measure,
      ingenuity: {
        observedAttempts: "2",
        positiveAttempts: positive,
        unknownAttempts: "0",
        total: null,
      },
    },
  });
  render(
    <MantineProvider>
      <CharacterComparison
        left={{
          truncated: false,
          nodes: [
            { ...row("2"), resourceAllocation: { ...measure, quantity: "0" } },
          ],
        }}
        right={{ truncated: false, nodes: [row("1")] }}
        resourceComparison
      />
    </MantineProvider>,
  );
  expect(
    screen.getByText(/−<0.01 percentage points per allocated unit/),
  ).toHaveTextContent("9,007,199,254,740,993 units");
});

it("reports a negative observed improvement per allocated unit", () => {
  const measure = {
    attempts: "2",
    measuredAttempts: "2",
    incompleteAttempts: "0",
    quantity: "4",
  };
  const row = (positive: string) => ({
    id: "A",
    name: "A",
    measure,
    resourceAllocation: measure,
    metrics: {
      ...extraOutcomes,
      production: measure,
      ingenuity: {
        observedAttempts: "2",
        positiveAttempts: positive,
        unknownAttempts: "0",
        total: null,
      },
    },
  });
  render(
    <MantineProvider>
      <CharacterComparison
        left={{
          truncated: false,
          nodes: [
            { ...row("2"), resourceAllocation: { ...measure, quantity: "0" } },
          ],
        }}
        right={{ truncated: false, nodes: [row("1")] }}
        resourceComparison
      />
    </MantineProvider>,
  );
  expect(
    screen.getByText(/−25.00 percentage points per allocated unit/),
  ).toBeInTheDocument();
});

it("withholds normalization when the item was also allocated in the baseline", () => {
  const measure = {
    attempts: "2",
    measuredAttempts: "2",
    incompleteAttempts: "0",
    quantity: "4",
  };
  const row = {
    id: "A",
    name: "A",
    measure,
    resourceAllocation: measure,
    metrics: {
      ...extraOutcomes,
      production: measure,
      ingenuity: {
        observedAttempts: "2",
        positiveAttempts: "1",
        unknownAttempts: "0",
        total: null,
      },
    },
  };
  render(
    <MantineProvider>
      <CharacterComparison
        left={{ truncated: false, nodes: [row] }}
        right={{ truncated: false, nodes: [row] }}
        resourceComparison
      />
    </MantineProvider>,
  );
  expect(
    screen.getByText("Insufficient complete evidence"),
  ).toBeInTheDocument();
});

it("does not display normalization for unrelated populations", () => {
  render(
    <MantineProvider>
      <CharacterComparison
        left={{ truncated: false, nodes: [] }}
        right={{ truncated: false, nodes: [] }}
      />
    </MantineProvider>,
  );
  expect(
    screen.queryByText("Difference per allocated unit"),
  ).not.toBeInTheDocument();
});
