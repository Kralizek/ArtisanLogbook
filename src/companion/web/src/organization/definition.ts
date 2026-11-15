import {
  isCharacterOutcome,
  type CharacterOutcome,
} from "../app/analysisScope";

export type Destination = "activity" | "recipe" | "item" | "crafts";
export type Period = "30" | "90" | "all" | "fixed";
export type Scope = {
  period: Period;
  from?: string;
  to?: string;
  character?: string;
  profession?: string;
  expansion?: string;
  recipe?: string;
  input?: string;
  absentInput?: string;
  output?: string;
  returned?: string;
  item?: string;
  configuration?: string;
  buff?: string;
  absentBuff?: string;
  finishing?: string;
  absentFinishing?: string;
};
export type SavedDefinition = {
  destination: Destination;
  entity?: string;
  scope: Scope;
  query: {
    granularity?: "day" | "week" | "month";
    compare?: Scope;
    characterOutcome?: CharacterOutcome;
    returnItem?: string;
  };
};

const fields = [
  "period",
  "from",
  "to",
  "character",
  "profession",
  "expansion",
  "recipe",
  "input",
  "absentInput",
  "output",
  "returned",
  "item",
  "configuration",
  "buff",
  "absentBuff",
  "finishing",
  "absentFinishing",
] as const;
const filters = fields.slice(3);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("This saved investigation has an unsupported definition.");
  return value as Record<string, unknown>;
}

function keys(value: Record<string, unknown>, allowed: readonly string[]) {
  if (Object.keys(value).some((key) => !allowed.includes(key)))
    throw new Error("This investigation contains unsupported filters.");
}

function date(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return (
    !Number.isNaN(parsed.valueOf()) &&
    parsed.toISOString().slice(0, 10) === value
  );
}

function scope(value: unknown): Scope {
  const record = object(value);
  keys(record, fields);
  if (
    typeof record.period !== "string" ||
    !["30", "90", "all", "fixed"].includes(record.period)
  )
    throw new Error("This investigation has an unsupported period.");
  if (record.period === "fixed") {
    if (!date(record.from) || !date(record.to) || record.from > record.to)
      throw new Error(
        "A fixed period needs valid ordered start and end dates.",
      );
  } else if (record.from !== undefined || record.to !== undefined) {
    throw new Error("Dates are only supported for fixed periods.");
  }
  for (const field of filters) {
    const filter = record[field];
    if (
      filter !== undefined &&
      (typeof filter !== "string" || !filter.trim() || filter.length > 512)
    )
      throw new Error("This investigation has an invalid filter.");
  }
  for (const field of ["buff", "absentBuff"] as const) {
    const spellId = record[field];
    if (
      spellId !== undefined &&
      (typeof spellId !== "string" ||
        !/^[1-9]\d*$/.test(spellId) ||
        !Number.isSafeInteger(Number(spellId)))
    )
      throw new Error("A recorded buff needs a positive spell ID.");
  }
  return record as Scope;
}

export function parseDefinition(
  value: unknown,
  version: number = 1,
): SavedDefinition {
  if (version !== 1)
    throw new Error("This saved investigation uses an unsupported version.");
  const record = object(value);
  keys(record, ["destination", "entity", "scope", "query"]);
  if (
    typeof record.destination !== "string" ||
    !["activity", "recipe", "item", "crafts"].includes(record.destination)
  )
    throw new Error("This investigation has an unsupported destination.");
  const hasEntity =
    record.destination === "recipe" || record.destination === "item";
  if (
    hasEntity
      ? typeof record.entity !== "string" ||
        !record.entity.trim() ||
        record.entity.length > 512
      : record.entity !== undefined
  )
    throw new Error("This investigation has an invalid entity.");
  const query = object(record.query);
  keys(query, ["granularity", "compare", "characterOutcome", "returnItem"]);
  if (
    query.granularity !== undefined &&
    (typeof query.granularity !== "string" ||
      !["day", "week", "month"].includes(query.granularity))
  )
    throw new Error("This investigation has unsupported granularity.");
  if (
    query.characterOutcome !== undefined &&
    (!isCharacterOutcome(query.characterOutcome) ||
      record.destination !== "recipe" ||
      query.compare === undefined)
  )
    throw new Error("This investigation has an unsupported character outcome.");
  if (
    query.returnItem !== undefined &&
    (query.characterOutcome !== "returns" ||
      typeof query.returnItem !== "string" ||
      !query.returnItem.trim() ||
      query.returnItem.length > 512)
  )
    throw new Error("This investigation has an invalid returned material.");
  return {
    destination: record.destination as Destination,
    ...(hasEntity ? { entity: record.entity as string } : {}),
    scope: scope(record.scope),
    query: {
      ...(query.granularity
        ? { granularity: query.granularity as "day" | "week" | "month" }
        : {}),
      ...(query.compare === undefined ? {} : { compare: scope(query.compare) }),
      ...(isCharacterOutcome(query.characterOutcome)
        ? { characterOutcome: query.characterOutcome }
        : {}),
      ...(typeof query.returnItem === "string"
        ? { returnItem: query.returnItem }
        : {}),
    },
  };
}

function fromSearch(search: URLSearchParams, prefix: string): Scope {
  const value: Record<string, string> = {};
  for (const field of fields) {
    const parameter = `${prefix}${field}`;
    if (search.has(parameter)) value[field] = search.get(parameter)!;
  }
  if (!search.has(`${prefix}period`)) value.period = "90";
  return scope(value);
}

export function definitionFromLocation(
  pathname: string,
  searchString: string,
  routeAlias: string,
): SavedDefinition {
  const path = pathname.split("/").map((part) => {
    try {
      return decodeURIComponent(part);
    } catch {
      throw new Error("This investigation has an invalid address.");
    }
  });
  if (path[0] !== "" || path[1] !== routeAlias)
    throw new Error("This investigation belongs to a different context.");
  let destination: Destination;
  let entity: string | undefined;
  if (path.length === 3 && (path[2] === "activity" || path[2] === "crafts"))
    destination = path[2];
  else if (
    path.length === 4 &&
    (path[2] === "recipes" || path[2] === "items")
  ) {
    destination = path[2] === "recipes" ? "recipe" : "item";
    entity = path[3];
  } else {
    throw new Error("Only analytical investigations can be saved here.");
  }
  const search = new URLSearchParams(searchString);
  const allowed = new Set([
    ...fields,
    ...fields.map((field) => `b${field}`),
    "granularity",
    "characterOutcome",
    "returnItem",
    "compare",
    "saved",
    "revision",
  ]);
  for (const [key] of search) {
    if (!allowed.has(key) || search.getAll(key).length !== 1)
      throw new Error(
        "This investigation has duplicate or unsupported filters.",
      );
  }
  if (search.has("saved") !== search.has("revision"))
    throw new Error(
      "This saved investigation has incomplete revision metadata.",
    );
  if (search.has("saved")) {
    if (
      !uuid.test(search.get("saved")!) ||
      !/^[1-9]\d*$/.test(search.get("revision")!) ||
      !Number.isSafeInteger(Number(search.get("revision")))
    )
      throw new Error(
        "This saved investigation has invalid revision metadata.",
      );
  }
  if (search.has("compare") && search.get("compare") !== "1")
    throw new Error("This investigation has an invalid comparison.");
  if (search.has("compare") && !search.has("bperiod"))
    throw new Error("A comparison needs its own period.");
  if (!search.has("compare") && fields.some((field) => search.has(`b${field}`)))
    throw new Error("Comparison filters require an active comparison.");
  const characterOutcome = search.get("characterOutcome");
  if (search.has("characterOutcome") && !isCharacterOutcome(characterOutcome))
    throw new Error("This investigation has an unsupported character outcome.");
  const definition: SavedDefinition = {
    destination,
    ...(entity ? { entity } : {}),
    scope: fromSearch(search, ""),
    query: {
      ...(search.has("granularity")
        ? { granularity: search.get("granularity") as "day" | "week" | "month" }
        : {}),
      ...(search.has("compare") ? { compare: fromSearch(search, "b") } : {}),
      ...(isCharacterOutcome(characterOutcome) ? { characterOutcome } : {}),
      ...(search.has("returnItem")
        ? { returnItem: search.get("returnItem")! }
        : {}),
    },
  };
  return parseDefinition(definition);
}

export function definitionUrl(
  definition: SavedDefinition,
  alias: string,
  origin?: { id: string; revision: number },
): string {
  const parsed = parseDefinition(definition);
  const path = `/${encodeURIComponent(alias)}/${
    {
      activity: "activity",
      crafts: "crafts",
      recipe: "recipes",
      item: "items",
    }[parsed.destination]
  }${parsed.entity ? `/${encodeURIComponent(parsed.entity)}` : ""}`;
  const search = new URLSearchParams();
  function append(value: Scope, prefix: string) {
    for (const field of fields) {
      const property = value[field];
      if (property !== undefined) search.set(`${prefix}${field}`, property);
    }
  }
  append(parsed.scope, "");
  if (parsed.query.granularity)
    search.set("granularity", parsed.query.granularity);
  if (parsed.query.characterOutcome)
    search.set("characterOutcome", parsed.query.characterOutcome);
  if (parsed.query.returnItem)
    search.set("returnItem", parsed.query.returnItem);
  if (parsed.query.compare) {
    search.set("compare", "1");
    append(parsed.query.compare, "b");
  }
  if (origin) {
    if (
      !uuid.test(origin.id) ||
      !Number.isSafeInteger(origin.revision) ||
      origin.revision < 1
    )
      throw new Error(
        "This saved investigation has invalid revision metadata.",
      );
    search.set("saved", origin.id);
    search.set("revision", String(origin.revision));
  }
  return `${path}?${search.toString()}`;
}
