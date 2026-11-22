import { useQuery } from "@apollo/client/react";
import {
  Accordion,
  Alert,
  Button,
  Group,
  Select,
  Stack,
  Text,
  TextInput,
} from "@mantine/core";
import { useDebouncedValue } from "@mantine/hooks";
import { useState, type ReactNode } from "react";
import { useSearchParams } from "react-router";
import type { ActiveGame } from "../app/game";
import { relativePeriodOrder, relativePeriods } from "../app/scope";
import { itemLabel } from "./analysisFormat";
import {
  WorkspaceFacetsDocument,
  WorkspaceFilterItemsDocument,
  WorkspaceSelectedItemDocument,
} from "../graphql/generated/graphql";

function retainSelection(
  choices: { value: string; label: string }[],
  selected: string | null,
  kind: string,
) {
  return selected && !choices.some((choice) => choice.value === selected)
    ? [
        { value: selected, label: `Selected ${kind} (outside listed choices)` },
        ...choices,
      ]
    : choices;
}

function FixedDates({
  from,
  through,
  prefix,
  apply,
}: {
  from: string;
  through: string;
  prefix: string;
  apply: (from: string, through: string) => void;
}) {
  const [start, setStart] = useState(from);
  const [end, setEnd] = useState(through);
  return (
    <>
      <TextInput
        type="date"
        label="From (UTC)"
        aria-label={`${prefix ? "Population B " : ""}From`}
        value={start}
        onChange={(event) => setStart(event.currentTarget.value)}
      />
      <TextInput
        type="date"
        label="Through (UTC)"
        aria-label={`${prefix ? "Population B " : ""}Through`}
        value={end}
        onChange={(event) => setEnd(event.currentTarget.value)}
      />
      <Button
        variant="default"
        disabled={!start || !end || start > end}
        onClick={() => apply(start, end)}
      >
        Apply dates
      </Button>
    </>
  );
}

export function ItemFilter({
  game,
  label,
  description,
  value,
  onChange,
}: {
  game: ActiveGame;
  label: string;
  description?: string;
  value: string | null;
  onChange: (value: string | null) => void;
}) {
  const [search, setSearch] = useState("");
  const [term] = useDebouncedValue(search, 250);
  const { data, error } = useQuery(WorkspaceFilterItemsDocument, {
    variables: { context: game.canonicalId, search: term },
    skip: term.trim().length < 2,
    fetchPolicy: "no-cache",
  });
  const { data: selectedData, error: selectedError } = useQuery(
    WorkspaceSelectedItemDocument,
    {
      variables: { context: game.canonicalId, id: value ?? "" },
      skip: !value,
      fetchPolicy: "no-cache",
    },
  );
  const options =
    data?.game.items.nodes.map((item) => ({
      value: item.id,
      label: itemLabel(item),
    })) ?? [];
  if (value && !options.some((item) => item.value === value)) {
    const item = selectedData?.contextItem;
    options.unshift({
      value,
      label:
        item?.id === value
          ? itemLabel(item)
          : "Selected item (search to change)",
    });
  }
  return (
    <Select
      label={label}
      aria-label={label}
      description={description}
      placeholder="Item name or #number"
      nothingFoundMessage={
        term.trim().length < 2 ? "Type at least 2 letters" : "No recorded item"
      }
      error={
        error || selectedError
          ? "Items could not be loaded. Try searching again."
          : undefined
      }
      searchable
      clearable
      clearButtonProps={{ "aria-label": `Clear ${label}` }}
      searchValue={search}
      onSearchChange={setSearch}
      value={value}
      onChange={(next) => {
        onChange(next);
        setSearch("");
      }}
      data={options}
      w={230}
    />
  );
}

function FilterSection({
  title,
  note,
  children,
}: {
  title: string;
  note?: string;
  children: ReactNode;
}) {
  return (
    <Stack gap={6}>
      <Text size="sm" fw={700}>
        {title}
      </Text>
      <Group align="start" gap="sm">
        {children}
      </Group>
      {note && (
        <Text size="xs" c="dimmed">
          {note}
        </Text>
      )}
    </Stack>
  );
}

// Buff names are not captured, so buffs are identified by spell ID. Offer the
// buffs recorded in this scope when known; otherwise accept a typed spell ID.
function BuffFilter({
  label,
  description,
  buffIds,
  value,
  onChange,
}: {
  label: string;
  description: string;
  buffIds: number[];
  value: string | null;
  onChange: (value: string | null) => void;
}) {
  const [draft, setDraft] = useState(value ?? "");
  const valid = draft === "" || /^[1-9]\d{0,9}$/.test(draft.trim());
  if (buffIds.length)
    return (
      <Select
        label={label}
        aria-label={label}
        description={description}
        placeholder="Any buff"
        clearable
        searchable
        clearButtonProps={{ "aria-label": `Clear ${label}` }}
        value={value}
        onChange={onChange}
        data={retainSelection(
          [...buffIds]
            .sort((a, b) => a - b)
            .map((id) => ({ value: String(id), label: `Spell ${id}` })),
          value,
          "buff",
        )}
        w={230}
      />
    );
  return (
    <TextInput
      label={label}
      aria-label={label}
      description={`${description}. Enter the buff's spell ID number.`}
      placeholder="Any buff"
      inputMode="numeric"
      value={draft}
      error={valid ? undefined : "Enter a whole spell ID number"}
      onChange={(event) => setDraft(event.currentTarget.value)}
      onBlur={() => {
        if (valid) onChange(draft.trim() || null);
      }}
      w={230}
    />
  );
}

export function ScopeControls({
  game,
  prefix = "",
  configurations,
  buffIds = [],
  hideRoleItems = false,
  focusedRecipe = false,
}: {
  game: ActiveGame;
  prefix?: string;
  configurations?: { value: string; label: string }[];
  /** Spell IDs of buffs recorded in this scope, offered as buff choices. */
  buffIds?: number[];
  hideRoleItems?: boolean;
  focusedRecipe?: boolean;
}) {
  const [params, setParams] = useSearchParams();
  const label = prefix ? "Population B " : "";
  const { data, error } = useQuery(WorkspaceFacetsDocument, {
    variables: { context: game.canonicalId },
    fetchPolicy: "no-cache",
  });
  const supportsRetailOptions = game.project === 1;
  const hasAdvancedFilters = [
    "input",
    "absentInput",
    "output",
    "returned",
    "item",
    "buff",
    "absentBuff",
    "finishing",
    "absentFinishing",
    "configuration",
    "expansion",
    "gameExpansion",
  ].some((key) => params.has(prefix + key));
  function set(key: string, value: string | null) {
    const next = new URLSearchParams(params);
    if (value) next.set(prefix + key, value);
    else next.delete(prefix + key);
    if (key === "period" && value !== "fixed") {
      next.delete(prefix + "from");
      next.delete(prefix + "to");
    }
    next.delete("after");
    setParams(next, { replace: true });
  }
  return (
    <Stack gap="xs" className="scope-controls">
      {prefix && <Text fw={600}>Population B · independent scope</Text>}
      <Group align="end" gap="sm">
        <Select
          label="Period"
          aria-label={`${prefix ? "Population B " : ""}Period`}
          value={params.get(prefix + "period") ?? "90"}
          onChange={(value) => set("period", value)}
          data={[
            ...relativePeriodOrder.map((value) => ({
              value,
              label: relativePeriods[value].label,
            })),
            { value: "all", label: "All history" },
            { value: "fixed", label: "Fixed dates" },
          ]}
          w={160}
        />
        {params.get(prefix + "period") === "fixed" && (
          <FixedDates
            key={`${params.get(prefix + "from")}:${params.get(prefix + "to")}`}
            prefix={prefix}
            from={params.get(prefix + "from") ?? ""}
            through={params.get(prefix + "to") ?? ""}
            apply={(from, to) => {
              const next = new URLSearchParams(params);
              next.set(prefix + "from", from);
              next.set(prefix + "to", to);
              next.delete("after");
              setParams(next);
            }}
          />
        )}
        {((data?.game.characters.nodes.length ?? 0) > 1 ||
          params.has(prefix + "character")) && (
          <Select
            label="Character"
            aria-label={`${prefix ? "Population B " : ""}Character`}
            placeholder="All characters"
            clearable
            clearButtonProps={{
              "aria-label": `Clear ${prefix ? "Population B " : ""}Character`,
            }}
            searchable
            value={params.get(prefix + "character")}
            onChange={(value) => set("character", value)}
            data={retainSelection(
              data?.game.characters.nodes.map((c) => ({
                value: c.id,
                label: c.name ?? "Unnamed character",
              })) ?? [],
              params.get(prefix + "character"),
              "character",
            )}
            w={200}
          />
        )}
        {(!focusedRecipe || params.has(prefix + "profession")) &&
          ((data?.game.professions.nodes.length ?? 0) > 1 ||
            params.has(prefix + "profession")) && (
            <>
              <Select
                label="Profession"
                aria-label={`${prefix ? "Population B " : ""}Profession`}
                placeholder="All professions"
                clearable
                clearButtonProps={{
                  "aria-label": `Clear ${prefix ? "Population B " : ""}Profession`,
                }}
                searchable
                value={params.get(prefix + "profession")}
                onChange={(value) => set("profession", value)}
                data={retainSelection(
                  data?.game.professions.nodes.map((p) => ({
                    value: p.id,
                    label: p.name ?? `Profession ${p.blizzardId}`,
                  })) ?? [],
                  params.get(prefix + "profession"),
                  "profession",
                )}
                w={180}
              />
            </>
          )}
      </Group>
      {(!hideRoleItems ||
        supportsRetailOptions ||
        hasAdvancedFilters ||
        !focusedRecipe) && (
        <Accordion defaultValue={hasAdvancedFilters ? "more-filters" : null}>
          <Accordion.Item value="more-filters">
            <Accordion.Control>
              More filters{hasAdvancedFilters ? " · active" : ""}
            </Accordion.Control>
            <Accordion.Panel>
              <Stack gap="md">
                <Text size="sm" c="dimmed">
                  Narrow which crafts are counted. A craft must match every
                  filter you set; leave a filter empty to ignore it.
                </Text>
                {((!focusedRecipe || params.has(prefix + "gameExpansion")) &&
                  !!data?.game.expansionGroups.nodes.length) ||
                params.has(prefix + "expansion") ? (
                  <FilterSection title="Expansion">
                    {(!focusedRecipe || params.has(prefix + "gameExpansion")) &&
                      !!data?.game.expansionGroups.nodes.length && (
                        <Select
                          label={`${label}Game expansion`}
                          aria-label={`${label}Game expansion`}
                          description="Crafts from that expansion's professions"
                          placeholder="All expansions"
                          clearable
                          clearButtonProps={{
                            "aria-label": `Clear ${label}Game expansion`,
                          }}
                          value={params.get(prefix + "gameExpansion")}
                          onChange={(value) => set("gameExpansion", value)}
                          data={data.game.expansionGroups.nodes.map((e) => ({
                            value: e.id,
                            label: e.name ?? "Unknown expansion",
                          }))}
                          w={230}
                        />
                      )}
                    {params.has(prefix + "expansion") && (
                      <Select
                        label={`${label}Legacy profession expansion`}
                        aria-label={`${label}Legacy profession expansion`}
                        description="From an older link: one profession's expansion only. Clear it to use Game expansion."
                        placeholder="All expansions"
                        clearable
                        clearButtonProps={{
                          "aria-label": `Clear ${label}Legacy profession expansion`,
                        }}
                        value={params.get(prefix + "expansion")}
                        onChange={(value) => set("expansion", value)}
                        data={
                          data?.game.expansions.nodes.map((e) => ({
                            value: e.id,
                            label: e.name ?? e.key,
                          })) ?? [
                            {
                              value: params.get(prefix + "expansion")!,
                              label: "Retained exact profession expansion",
                            },
                          ]
                        }
                        w={260}
                      />
                    )}
                  </FilterSection>
                ) : null}
                {!hideRoleItems && (
                  <FilterSection
                    title="Reagents and results"
                    note={`"Didn't use" only matches crafts whose reagents were fully recorded; crafts with missing records are left out rather than assumed not to use it.`}
                  >
                    <ItemFilter
                      game={game}
                      label={`${label}Used reagent`}
                      description="Crafts that used this item as a reagent"
                      value={params.get(prefix + "input")}
                      onChange={(value) => set("input", value)}
                    />
                    <ItemFilter
                      game={game}
                      label={`${label}Didn't use reagent`}
                      description={
                        game.project === 18
                          ? "Crafts whose recipe didn't require this item"
                          : "Crafts recorded without this reagent"
                      }
                      value={params.get(prefix + "absentInput")}
                      onChange={(value) => set("absentInput", value)}
                    />
                    <ItemFilter
                      game={game}
                      label={`${label}Produced item`}
                      description="Crafts whose result included this item"
                      value={params.get(prefix + "output")}
                      onChange={(value) => set("output", value)}
                    />
                    {supportsRetailOptions && (
                      <ItemFilter
                        game={game}
                        label={`${label}Got back reagent`}
                        description="Crafts that returned this item (Resourcefulness)"
                        value={params.get(prefix + "returned")}
                        onChange={(value) => set("returned", value)}
                      />
                    )}
                    <ItemFilter
                      game={game}
                      label={`${label}Involves item`}
                      description="Used, produced or returned in any role"
                      value={params.get(prefix + "item")}
                      onChange={(value) => set("item", value)}
                    />
                  </FilterSection>
                )}
                {(supportsRetailOptions ||
                  !!configurations?.length ||
                  !!params.get(prefix + "configuration")) && (
                  <FilterSection
                    title="Crafting setup"
                    note={
                      supportsRetailOptions
                        ? `"Not used" and "not active" only match crafts whose selections were fully recorded; missing evidence never counts as absent.`
                        : undefined
                    }
                  >
                    {(!!configurations?.length ||
                      !!params.get(prefix + "configuration")) && (
                      <Select
                        label={`${label}Recorded setup`}
                        aria-label={`${label}Recorded setup`}
                        description="One exact recorded combination of skill, stats, equipment, buffs and finishing reagents"
                        placeholder="Any setup"
                        clearable
                        clearButtonProps={{
                          "aria-label": `Clear ${label}Recorded setup`,
                        }}
                        value={params.get(prefix + "configuration")}
                        onChange={(value) => set("configuration", value)}
                        data={
                          params.get(prefix + "configuration") &&
                          !configurations?.some(
                            (choice) =>
                              choice.value ===
                              params.get(prefix + "configuration"),
                          )
                            ? [
                                {
                                  value: params.get(prefix + "configuration")!,
                                  label:
                                    "Selected setup (not in current results)",
                                },
                                ...(configurations ?? []),
                              ]
                            : (configurations ?? [])
                        }
                        w={300}
                      />
                    )}
                    {supportsRetailOptions && (
                      <>
                        <ItemFilter
                          game={game}
                          label={`${label}Finishing reagent used`}
                          description="Crafts that submitted this finishing reagent"
                          value={params.get(prefix + "finishing")}
                          onChange={(value) => set("finishing", value)}
                        />
                        <ItemFilter
                          game={game}
                          label={`${label}Finishing reagent not used`}
                          description="Crafts recorded without this finishing reagent"
                          value={params.get(prefix + "absentFinishing")}
                          onChange={(value) => set("absentFinishing", value)}
                        />
                        <BuffFilter
                          label={`${label}Buff active`}
                          description="Crafts made with this buff recorded"
                          buffIds={buffIds}
                          value={params.get(prefix + "buff")}
                          onChange={(value) => set("buff", value)}
                        />
                        <BuffFilter
                          label={`${label}Buff not active`}
                          description="Crafts recorded without this buff"
                          buffIds={buffIds}
                          value={params.get(prefix + "absentBuff")}
                          onChange={(value) => set("absentBuff", value)}
                        />
                      </>
                    )}
                  </FilterSection>
                )}
              </Stack>
            </Accordion.Panel>
          </Accordion.Item>
        </Accordion>
      )}
      {error && (
        <Alert color="yellow">
          Filter choices could not be loaded. Existing investigation filters are
          preserved.
        </Alert>
      )}
      {(data?.game.characters.pageInfo.hasNextPage ||
        data?.game.professions.pageInfo.hasNextPage ||
        data?.game.expansions.pageInfo.hasNextPage ||
        data?.game.expansionGroups.truncated) && (
        <Text size="xs" c="dimmed">
          The first 100 choices are shown. Existing explicit filters still
          apply.
        </Text>
      )}
    </Stack>
  );
}
