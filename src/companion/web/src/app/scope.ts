import type { ActiveGame } from "./game";

export const dimensionKeys = [
  "character",
  "profession",
  "expansion",
  "gameExpansion",
  "recipe",
  "input",
  "absentInput",
  "output",
  "returned",
  "item",
  "configuration",
] as const;
export type DimensionKey = (typeof dimensionKeys)[number];
export const comparisonFields = [
  "period",
  "from",
  "to",
  ...dimensionKeys,
  "buff",
  "absentBuff",
  "finishing",
  "absentFinishing",
] as const;

// Rolling periods cover whole UTC calendar days ending today, so a chart of an
// N-day period has exactly N daily columns. "today" is the current UTC day.
export const relativePeriods = {
  today: { days: 1, label: "Today (UTC)" },
  "7": { days: 7, label: "Last 7 days" },
  "30": { days: 30, label: "Last 30 days" },
  "90": { days: 90, label: "Last 90 days" },
} as const;
export type RelativePeriod = keyof typeof relativePeriods;
// Display order; numeric object keys would otherwise sort before "today".
export const relativePeriodOrder: readonly RelativePeriod[] = [
  "today",
  "7",
  "30",
  "90",
];

export function isRelativePeriod(
  period: string | null,
): period is RelativePeriod {
  return period !== null && Object.hasOwn(relativePeriods, period);
}

export function periodBounds(
  params: URLSearchParams,
  prefix = "",
  now = new Date(),
) {
  const period = params.get(`${prefix}period`) ?? "90";
  if (period === "all") return {};
  if (period === "fixed") {
    const from = params.get(`${prefix}from`);
    const to = params.get(`${prefix}to`);
    if (
      !from ||
      !to ||
      !/^\d{4}-\d{2}-\d{2}$/.test(from) ||
      !/^\d{4}-\d{2}-\d{2}$/.test(to) ||
      !Number.isFinite(Date.parse(from)) ||
      !Number.isFinite(Date.parse(to)) ||
      new Date(from).toISOString().slice(0, 10) !== from ||
      new Date(to).toISOString().slice(0, 10) !== to ||
      from > to
    )
      throw new Error(
        "Choose a valid start and end date for this investigation.",
      );
    return {
      from: `${from}T00:00:00.0000000Z`,
      to: `${to}T23:59:59.9999999Z`,
    };
  }
  if (!isRelativePeriod(period))
    throw new Error("This investigation has an unsupported period.");
  const start = new Date(now);
  start.setUTCHours(0, 0, 0, 0);
  start.setUTCDate(start.getUTCDate() - (relativePeriods[period].days - 1));
  return { from: start.toISOString(), to: now.toISOString() };
}

export function investigationLink(
  game: ActiveGame,
  destination: string,
  params?: URLSearchParams,
  changes: Record<string, string | null> = {},
) {
  const next = new URLSearchParams(params);
  next.delete("after");
  next.delete("saved");
  next.delete("revision");
  next.delete("characterOutcome");
  next.delete("returnItem");
  for (const [key, value] of Object.entries(changes)) {
    if (value === null) next.delete(key);
    else next.set(key, value);
  }
  // A recipe page is already scoped to the recipe in its path.
  if (destination.startsWith("recipes/")) next.delete("recipe");
  return `/${game.routeAlias}/${destination}${next.size ? `?${next}` : ""}`;
}

export function scopeLabel(params: URLSearchParams, prefix = "") {
  const period = params.get(`${prefix}period`) ?? "90";
  return period === "all"
    ? "All recorded history"
    : period === "fixed"
      ? `${params.get(`${prefix}from`)} – ${params.get(`${prefix}to`)}`
      : isRelativePeriod(period)
        ? relativePeriods[period].label
        : `Period ${period}`;
}
