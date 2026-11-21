import { Alert, Select, Stack, Table, Text, Title } from "@mantine/core";
import type { ReactNode } from "react";
import type { CharacterOutcome } from "../app/analysisScope";
import type {
  CharacterReturnsQuery,
  RecipeInvestigationQuery,
} from "../graphql/generated/graphql";
import {
  coverage,
  exact,
  measuredCraftAverage,
  observedRateDifference,
  rate,
} from "./analysisFormat";

type Characters = RecipeInvestigationQuery["analysis"]["characters"];
type Character = Characters["nodes"][number];
type Metric = CharacterOutcome;
type Fraction = { numerator: bigint; denominator: bigint };
type ReturnRows = CharacterReturnsQuery["analysis"]["characters"];
type ReturnMeasure = ReturnRows["nodes"][number]["returnedItem"];

const retailMetrics: { value: Metric; label: string }[] = [
  { value: "ingenuity", label: "Ingenuity proc rate" },
  { value: "resourcefulness", label: "Resourcefulness proc rate" },
  { value: "multicraft", label: "Multicraft bonus occurrence" },
  { value: "returns", label: "Returned material per craft" },
];
const productionMetric = {
  value: "production" as const,
  label: "Actual output per craft",
};

export function CharacterComparison({
  left,
  right,
  resourceComparison = false,
  attributedRequirements = false,
  includeRetailOutcomes = true,
  metric,
  onMetricChange,
  returnItemControl,
  leftReturns,
  rightReturns,
}: {
  left: Characters;
  right: Characters;
  resourceComparison?: boolean;
  attributedRequirements?: boolean;
  includeRetailOutcomes?: boolean;
  metric: Metric;
  onMetricChange: (value: Metric) => void;
  returnItemControl?: ReactNode;
  leftReturns?: ReturnRows;
  rightReturns?: ReturnRows;
}) {
  const choices = includeRetailOutcomes
    ? [...retailMetrics, productionMetric]
    : [productionMetric];
  const rows = new Map<string, { left?: Character; right?: Character }>();
  for (const row of left.nodes) {
    if (row.id) rows.set(row.id, { left: row });
  }
  for (const row of right.nodes) {
    if (!row.id) continue;
    const pair = rows.get(row.id);
    if (pair) pair.right = row;
    else rows.set(row.id, { right: row });
  }
  const returned = (rows: ReturnRows | undefined, row: Character | undefined) =>
    rows?.nodes.find((item) => item.id === row?.id)?.returnedItem;
  const describe = (
    row: Character | undefined,
    returns: ReturnMeasure | undefined,
  ) => {
    if (!row) return "No matching population";
    if (metric === "returns") {
      return returns
        ? `${measuredCraftAverage(returns)} · ${coverage(returns)}`
        : "Choose a returned material or refresh the investigation";
    }
    if (metric === "production") {
      const measure = row.metrics?.production;
      return measure
        ? `${measuredCraftAverage(measure)} · ${coverage(measure)}`
        : `${exact(row.measure.attempts)} attempts · not measured`;
    }
    const outcome = row.metrics?.[metric];
    if (!outcome)
      return `${exact(row.measure.attempts)} attempts · not observed`;
    return `${rate(outcome) ?? "Not observed"} · ${exact(outcome.observedAttempts)} observed of ${exact(row.measure.attempts)} attempts`;
  };
  return (
    <Stack gap="xs">
      <Title order={3}>Observed changes by character</Title>
      <Text size="sm" c="dimmed">
        To investigate a resource, choose its confirmed absence in A and its
        presence in B. Compare measurement coverage and recorded setups; these
        differences are not causal effects. Actual output counts units across
        recorded output items; inspect individual items when their mix differs.
      </Text>
      <Select
        label="Outcome to compare"
        value={metric}
        data={choices}
        allowDeselect={false}
        onChange={(value) => {
          const choice = choices.find((item) => item.value === value);
          if (choice) onMetricChange(choice.value);
        }}
      />
      {metric === "returns" && returnItemControl}
      {metric === "returns" && (
        <Text size="sm" c="dimmed">
          Only complete return records with a known quantity are measured. A
          material absent from a complete return record counts as zero; an
          unknown quantity does not.
        </Text>
      )}
      <Table.ScrollContainer minWidth={720}>
        <Table striped withTableBorder>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Character</Table.Th>
              <Table.Th>Population A</Table.Th>
              <Table.Th>Population B</Table.Th>
              <Table.Th>Observed difference</Table.Th>
              {resourceComparison && (
                <Table.Th>
                  Difference per{" "}
                  {attributedRequirements ? "attributed" : "allocated"} unit
                </Table.Th>
              )}
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {[...rows.values()].map(({ left: a, right: b }) => (
              <Table.Tr key={a?.id ?? b?.id}>
                <Table.Td>{a?.name ?? b?.name ?? "Unnamed character"}</Table.Td>
                <Table.Td>{describe(a, returned(leftReturns, a))}</Table.Td>
                <Table.Td>{describe(b, returned(rightReturns, b))}</Table.Td>
                <Table.Td>
                  {difference(
                    a,
                    b,
                    metric,
                    returned(leftReturns, a),
                    returned(rightReturns, b),
                  )}
                </Table.Td>
                {resourceComparison && (
                  <Table.Td>
                    {differencePerAllocatedUnit(
                      a,
                      b,
                      metric,
                      attributedRequirements,
                      returned(leftReturns, a),
                      returned(rightReturns, b),
                    )}
                  </Table.Td>
                )}
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      </Table.ScrollContainer>
      {resourceComparison && (
        <Text size="sm" c="dimmed">
          {attributedRequirements
            ? "The difference is divided by the average attributed schematic requirements per B craft, not measured consumption. It requires complete input and outcome observations in both populations, with no attributed requirement for this item in A."
            : "The difference is divided by the average recorded allocation per B craft, not actual consumption. Allocations can originate from a multi-craft request and may be repeated across crafts. It requires complete allocation and outcome observations in both populations, with no recorded allocation of this item in A."}{" "}
          It is not a causal effect.
        </Text>
      )}
      {(left.truncated ||
        right.truncated ||
        leftReturns?.truncated ||
        rightReturns?.truncated) && (
        <Alert color="yellow">
          Character lists are truncated; not every population is shown.
        </Alert>
      )}
      {!rows.size && (
        <Text c="dimmed">No identifiable characters in these populations.</Text>
      )}
    </Stack>
  );
}

function metricFraction(
  row: Character | undefined,
  metric: Metric,
  complete: boolean,
  returns?: ReturnMeasure,
): Fraction | undefined {
  if (!row) return undefined;
  if (metric === "production" || metric === "returns") {
    const measure = metric === "production" ? row.metrics?.production : returns;
    if (
      !measure ||
      measure.quantity == null ||
      BigInt(measure.incompleteAttempts) !== 0n ||
      BigInt(measure.measuredAttempts) === 0n ||
      (complete && measure.measuredAttempts !== row.measure.attempts)
    )
      return undefined;
    const match = /^(\d+)(?:\.(\d+))?$/.exec(measure.quantity);
    if (!match) return undefined;
    return {
      numerator: BigInt(match[1] + (match[2] ?? "")),
      denominator:
        BigInt(measure.measuredAttempts) * 10n ** BigInt(match[2]?.length ?? 0),
    };
  }
  if (!row.metrics) return undefined;
  const outcome = row.metrics[metric];
  if (
    !outcome ||
    BigInt(outcome.observedAttempts) === 0n ||
    (complete && outcome.observedAttempts !== row.measure.attempts)
  )
    return undefined;
  return {
    numerator: BigInt(outcome.positiveAttempts),
    denominator: BigInt(outcome.observedAttempts),
  };
}

function difference(
  a: Character | undefined,
  b: Character | undefined,
  metric: Metric,
  leftReturns?: ReturnMeasure,
  rightReturns?: ReturnMeasure,
) {
  if (metric !== "production" && metric !== "returns") {
    const left = a?.metrics?.[metric];
    const right = b?.metrics?.[metric];
    return left && right
      ? (observedRateDifference(left, right) ??
          "Insufficient observed evidence")
      : "Insufficient observed evidence";
  }
  const left = metricFraction(a, metric, false, leftReturns);
  const right = metricFraction(b, metric, false, rightReturns);
  if (!left || !right) return "Insufficient observed evidence";
  return `B − A: ${formatDifference(left, right, 1n)} ${metric === "returns" ? "returned" : "output"} units per measured craft`;
}

function formatDifference(
  left: Fraction,
  right: Fraction,
  multiplier: bigint,
  divisor = 1n,
) {
  const numerator =
    (right.numerator * left.denominator - left.numerator * right.denominator) *
    multiplier;
  const denominator = left.denominator * right.denominator * divisor;
  const scaled = (numerator < 0n ? -numerator : numerator) * 100n;
  const rounded = (scaled + denominator / 2n) / denominator;
  const sign = numerator < 0n ? "−" : numerator > 0n ? "+" : "";
  if (rounded === 0n && numerator !== 0n) return `${sign}<0.01`;
  const approximate = scaled % denominator !== 0n ? "≈ " : "";
  return `${approximate}${sign}${rounded / 100n}.${String(rounded % 100n).padStart(2, "0")}`;
}

function differencePerAllocatedUnit(
  left: Character | undefined,
  right: Character | undefined,
  metric: Metric,
  attributedRequirements: boolean,
  leftReturns?: ReturnMeasure,
  rightReturns?: ReturnMeasure,
): string {
  const baseline = left?.resourceAllocation;
  const allocation = right?.resourceAllocation;
  const a = metricFraction(left, metric, true, leftReturns);
  const b = metricFraction(right, metric, true, rightReturns);
  if (
    !left ||
    !right ||
    !a ||
    !b ||
    !baseline ||
    baseline.quantity == null ||
    BigInt(baseline.quantity) !== 0n ||
    BigInt(baseline.incompleteAttempts) !== 0n ||
    baseline.measuredAttempts !== left.measure.attempts ||
    baseline.attempts !== left.measure.attempts ||
    !allocation ||
    allocation.quantity == null ||
    BigInt(allocation.quantity) <= 0n ||
    BigInt(allocation.incompleteAttempts) !== 0n ||
    allocation.measuredAttempts !== right.measure.attempts ||
    allocation.attempts !== right.measure.attempts
  )
    return "Insufficient complete evidence";
  const multiplier =
    BigInt(right.measure.attempts) *
    (metric === "production" || metric === "returns" ? 1n : 100n);
  const value = formatDifference(a, b, multiplier, BigInt(allocation.quantity));
  const unit =
    metric === "production"
      ? "output units"
      : metric === "returns"
        ? "returned units"
        : "percentage points";
  return `${value} ${unit} per ${attributedRequirements ? "attributed" : "allocated"} unit per B craft (${exact(allocation.quantity)} units / ${exact(allocation.attempts)} crafts)`;
}
