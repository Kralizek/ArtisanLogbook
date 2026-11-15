import type {
  CraftFilterInput,
  AnalysisGranularity,
} from "../graphql/generated/graphql";
import { periodBounds } from "./scope";

const ids = {
  character: "characterId",
  profession: "professionId",
  expansion: "expansionId",
  recipe: "recipeId",
  input: "inputItemId",
  output: "outputItemId",
  returned: "returnedItemId",
  item: "itemId",
  configuration: "configurationId",
  finishing: "finishingItemId",
  absentFinishing: "absentFinishingItemId",
} as const;

export function analysisFilter(
  params: URLSearchParams,
  prefix = "",
  recipeId?: string,
  now?: Date,
): CraftFilterInput {
  const filter: CraftFilterInput = { ...periodBounds(params, prefix, now) };
  for (const [parameter, field] of Object.entries(ids)) {
    const value = params.get(prefix + parameter);
    if (value) Object.assign(filter, { [field]: value });
  }
  if (recipeId) filter.recipeId = recipeId;
  for (const [parameter, field] of [
    ["buff", "buffSpellId"],
    ["absentBuff", "absentBuffSpellId"],
  ] as const) {
    const value = params.get(prefix + parameter);
    if (value !== null) {
      if (
        !/^[1-9]\d*$/.test(value) ||
        !Number.isSafeInteger(Number(value)) ||
        Number(value) > 2147483647
      )
        throw new Error(
          "Choose a valid positive spell ID for the recorded buff filter.",
        );
      filter[field] = Number(value);
    }
  }
  return filter;
}

export type ItemRole = "output" | "input" | "returned";

export function roleFilter(
  params: URLSearchParams,
  id: string,
  role: ItemRole,
  now?: Date,
): CraftFilterInput {
  const independent = new URLSearchParams(params);
  for (const key of ["item", "input", "output", "returned"])
    independent.delete(key);
  independent.set(role, id);
  return analysisFilter(independent, "", undefined, now);
}

export function itemRelationFilter(
  params: URLSearchParams,
  id: string,
  now?: Date,
): CraftFilterInput {
  const independent = new URLSearchParams(params);
  for (const key of ["item", "input", "output", "returned"])
    independent.delete(key);
  independent.set("item", id);
  return analysisFilter(independent, "", undefined, now);
}

export function roleLinkParams(
  params: URLSearchParams,
  id: string,
  role: ItemRole,
) {
  const next = new URLSearchParams(params);
  for (const key of ["item", "input", "output", "returned", "after"])
    next.delete(key);
  next.set(role, id);
  return next;
}

export function analysisGranularity(
  params: URLSearchParams,
): AnalysisGranularity {
  const value = params.get("granularity") ?? "day";
  if (value !== "day" && value !== "week" && value !== "month")
    throw new Error("This investigation has an unsupported time grouping.");
  return value.toUpperCase() as AnalysisGranularity;
}
