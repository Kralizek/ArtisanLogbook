import type { InvestigationCraftsQuery } from "../graphql/generated/graphql";

export type LogbookCraft =
  InvestigationCraftsQuery["contextCrafts"]["nodes"][number];

type Highlight = { kind: string; label: string; detail: string };

/**
 * The addon's per-craft highlights: Concentration spent, Multicraft bonus,
 * Ingenuity and Resourcefulness returns. Only recorded positive outcomes show;
 * an unknown or false outcome leaves no highlight rather than claiming zero.
 */
export function craftHighlights(craft: LogbookCraft): Highlight[] {
  const highlights: Highlight[] = [];
  if (craft.concentrationSpent && craft.concentrationSpent > 0)
    highlights.push({
      kind: "concentration",
      label: `Concentration ${craft.concentrationSpent.toLocaleString()}`,
      detail: `${craft.concentrationSpent.toLocaleString()} Concentration spent`,
    });
  if (craft.multicraftBonus && craft.multicraftBonus > 0)
    highlights.push({
      kind: "multicraft",
      label: `Multicraft +${craft.multicraftBonus.toLocaleString()}`,
      detail: `Multicraft produced ${craft.multicraftBonus.toLocaleString()} additional items`,
    });
  if (craft.hasIngenuityProc) {
    const refund = craft.appliedIngenuityRefund;
    highlights.push({
      kind: "ingenuity",
      label: refund ? `Ingenuity +${refund.toLocaleString()}` : "Ingenuity",
      detail: refund
        ? `Ingenuity refunded ${refund.toLocaleString()} Concentration`
        : "Ingenuity proc",
    });
  }
  const returned = (craft.reagents ?? []).reduce(
    (total, reagent) =>
      total + Math.max(0, Number(reagent.returnedQuantityExact ?? 0)),
    0,
  );
  if (returned > 0)
    highlights.push({
      kind: "resourcefulness",
      label: `Resourcefulness ${returned.toLocaleString()}`,
      detail: `Resourcefulness returned ${returned.toLocaleString()} material ${returned === 1 ? "unit" : "units"}`,
    });
  return highlights;
}

/** "21 Nov 18:40", the addon's 24-hour day-month format; full time on hover. */
export function shortTime(value: string) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", {
      day: "numeric",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    })
      .formatToParts(new Date(value))
      .map((part) => [part.type, part.value]),
  );
  return `${parts.day} ${parts.month} ${parts.hour}:${parts.minute}`;
}
