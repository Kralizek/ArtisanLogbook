import type { OutcomeRow } from "./OutcomeComparison";
import type { ConfigurationEvidence } from "./AnalysisEvidence";

export function configurationLabel(
  id: string,
  evidence: ConfigurationEvidence,
) {
  // A display-only code keeps the same setup recognizable across filtered populations.
  let code = 2166136261;
  for (const character of id)
    code = Math.imul(code ^ character.charCodeAt(0), 16777619) >>> 0;
  const skill = evidence.statistics?.find((stat) =>
    /^base skill$/i.test(stat.label),
  );
  return `Recorded setup ${code.toString(36).toUpperCase()}${skill ? ` · skill ${skill.value}` : ""}`;
}

type Measure = {
  attempts: string;
  measuredAttempts: string;
  incompleteAttempts: string;
  quantity?: string | null;
};
type Outcome = {
  observedAttempts: string;
  positiveAttempts: string;
  unknownAttempts: string;
  total?: string | null;
};
export type Metrics = {
  production: Measure;
  ingenuity?: Outcome | null;
  resourcefulness?: Outcome | null;
  multicraft?: Outcome | null;
  concentration?: Outcome | null;
  refund?: Outcome | null;
};

export function exact(value: string | null | undefined): string {
  if (value == null) return "Not measured";
  const match = /^(-?)(\d+)(\.\d+)?$/.exec(value);
  const fraction = match?.[3]?.replace(/0+$/, "").replace(/\.$/, "") ?? "";
  return match
    ? `${match[1]}${BigInt(match[2]).toLocaleString()}${fraction}`
    : value;
}

export function rawQuantity(value: number | string | null | undefined): string {
  if (value == null) return "Unknown";
  if (typeof value === "number" && !Number.isInteger(value))
    return "Exact decimal precision unavailable in browser";
  if (typeof value === "number" && !Number.isSafeInteger(value))
    return "Exceeds exact browser precision";
  return typeof value === "string" ? exact(value) : value.toLocaleString();
}

export function coverage(measure: Measure): string {
  return `Amount measured on ${exact(measure.measuredAttempts)} of ${exact(measure.attempts)} attempts · ${exact(measure.incompleteAttempts)} with incomplete evidence (counts may overlap)`;
}

export function measuredCraftAverage(measure: Measure): string {
  if (BigInt(measure.incompleteAttempts) > 0n)
    return "Per-craft average unavailable: incomplete observations contribute partial quantities";
  if (measure.quantity == null || BigInt(measure.measuredAttempts) === 0n)
    return "Per-craft average not measured";
  const match = /^(-?)(\d+)(?:\.(\d+))?$/.exec(measure.quantity);
  if (!match) return "Per-craft average unavailable";
  const numerator = BigInt(match[2] + (match[3] ?? ""));
  const denominator =
    BigInt(measure.measuredAttempts) * 10n ** BigInt(match[3]?.length ?? 0);
  const scaled = numerator * 1_000_000n;
  const rounded = (scaled + denominator / 2n) / denominator;
  const whole = (rounded / 1_000_000n).toLocaleString();
  const fraction = String(rounded % 1_000_000n)
    .padStart(6, "0")
    .replace(/0+$/, "");
  const value = `${match[1]}${whole}${fraction ? `.${fraction}` : ""}`;
  const approximate = scaled % denominator !== 0n;
  return `${approximate ? "≈ " : ""}${value} per measured craft${
    approximate
      ? ` (exact ratio: ${exact(measure.quantity)} ÷ ${exact(measure.measuredAttempts)})`
      : ""
  }`;
}

export function rate(outcome: Outcome): string | undefined {
  const denominator = BigInt(outcome.observedAttempts);
  if (denominator === 0n) return undefined;
  const tenths =
    (BigInt(outcome.positiveAttempts) * 1000n + denominator / 2n) / denominator;
  if (tenths === 0n && BigInt(outcome.positiveAttempts) > 0n)
    return "<0.1% of observed attempts";
  return `${tenths / 10n}.${tenths % 10n}% of observed attempts`;
}

export function observedRateDifference(
  left: Pick<Outcome, "observedAttempts" | "positiveAttempts">,
  right: Pick<Outcome, "observedAttempts" | "positiveAttempts">,
): string | null {
  const leftCount = BigInt(left.observedAttempts);
  const rightCount = BigInt(right.observedAttempts);
  if (leftCount === 0n || rightCount === 0n) return null;
  const numerator =
    BigInt(right.positiveAttempts) * leftCount -
    BigInt(left.positiveAttempts) * rightCount;
  const denominator = leftCount * rightCount;
  const tenths =
    ((numerator < 0n ? -numerator : numerator) * 1000n + denominator / 2n) /
    denominator;
  const sign = numerator < 0n ? "−" : numerator > 0n ? "+" : "";
  if (tenths === 0n && numerator !== 0n)
    return `B − A observed rate: ${sign}<0.1 percentage points`;
  return `B − A observed rate: ${sign}${tenths / 10n}.${tenths % 10n} percentage points`;
}

export function outcomeRows(
  attempts: string,
  metrics: Metrics,
  includeRetailOutcomes = true,
): OutcomeRow[] {
  const rows: OutcomeRow[] = [
    {
      label: "Actual production",
      value: exact(metrics.production.quantity),
      normalized: measuredCraftAverage(metrics.production),
      coverage: `${exact(metrics.production.measuredAttempts)} of ${exact(metrics.production.attempts)} complete output sets · ${exact(metrics.production.incompleteAttempts)} incomplete sets. Known partial quantities are included in the total.`,
    },
  ];
  if (!includeRetailOutcomes) return rows;
  for (const [label, outcome] of [
    ["Ingenuity procs", metrics.ingenuity],
    ["Resourcefulness procs", metrics.resourcefulness],
    ["Multicraft bonus", metrics.multicraft],
    ["Concentration spent", metrics.concentration],
    ["Ingenuity refund", metrics.refund],
  ] as const) {
    if (!outcome) continue;
    rows.push({
      label,
      value: `${exact(outcome.positiveAttempts)} positive · ${exact(outcome.total)} total`,
      normalized: rate(outcome),
      observed: {
        positiveAttempts: outcome.positiveAttempts,
        observedAttempts: outcome.observedAttempts,
      },
      coverage: `${exact(outcome.observedAttempts)} observed of ${exact(attempts)} attempts · ${exact(outcome.unknownAttempts)} unknown`,
    });
  }
  return rows;
}
