import type { ActiveGame } from "./game";

export const dimensionKeys = [
  "character",
  "profession",
  "expansion",
  "recipe",
  "input",
  "output",
  "returned",
  "item",
  "configuration",
] as const;
export type DimensionKey = (typeof dimensionKeys)[number];

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
  if (period !== "30" && period !== "90")
    throw new Error("This investigation has an unsupported period.");
  return {
    from: new Date(now.getTime() - Number(period) * 86400000).toISOString(),
    to: now.toISOString(),
  };
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
  for (const [key, value] of Object.entries(changes)) {
    if (value === null) next.delete(key);
    else next.set(key, value);
  }
  return `/${game.routeAlias}/${destination}${next.size ? `?${next}` : ""}`;
}

export function scopeLabel(params: URLSearchParams, prefix = "") {
  const period = params.get(`${prefix}period`) ?? "90";
  return period === "all"
    ? "All recorded history"
    : period === "fixed"
      ? `${params.get(`${prefix}from`)} – ${params.get(`${prefix}to`)}`
      : `Last ${period} days`;
}
