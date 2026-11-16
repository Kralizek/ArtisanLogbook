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
import { useState } from "react";
import { useSearchParams } from "react-router";
import type { ActiveGame } from "../app/game";
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
  value,
  onChange,
}: {
  game: ActiveGame;
  label: string;
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
      label: item.name
        ? `${item.name} · #${item.blizzardId}`
        : `Item ${item.blizzardId} · name unavailable`,
    })) ?? [];
  if (value && !options.some((item) => item.value === value)) {
    const item = selectedData?.contextItem;
    options.unshift({
      value,
      label:
        item?.id === value
          ? item.name
            ? `${item.name} · #${item.blizzardId}`
            : `Item ${item.blizzardId} · name unavailable`
          : "Selected item (search to change)",
    });
  }
  return (
    <Select
      label={label}
      aria-label={label}
      placeholder="Search item name"
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
      w={205}
    />
  );
}

export function ScopeControls({
  game,
  prefix = "",
  configurations,
  hideRoleItems = false,
  focusedRecipe = false,
}: {
  game: ActiveGame;
  prefix?: string;
  configurations?: { value: string; label: string }[];
  hideRoleItems?: boolean;
  focusedRecipe?: boolean;
}) {
  const [params, setParams] = useSearchParams();
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
            { value: "30", label: "Last 30 days" },
            { value: "90", label: "Last 90 days" },
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
              <Stack gap="xs">
                <Group align="end" gap="sm">
                  {(!focusedRecipe || params.has(prefix + "gameExpansion")) &&
                    !!data?.game.expansionGroups.nodes.length && (
                      <Select
                        label="Game expansion"
                        aria-label={`${prefix ? "Population B " : ""}Game expansion`}
                        placeholder="All expansions"
                        clearable
                        clearButtonProps={{
                          "aria-label": `Clear ${prefix ? "Population B " : ""}Game expansion`,
                        }}
                        value={params.get(prefix + "gameExpansion")}
                        onChange={(value) => set("gameExpansion", value)}
                        data={data.game.expansionGroups.nodes.map((e) => ({
                          value: e.id,
                          label: e.name ?? "Unknown expansion",
                        }))}
                        w={180}
                      />
                    )}
                  {params.has(prefix + "expansion") && (
                    <Select
                      label="Legacy profession expansion"
                      aria-label={`${prefix ? "Population B " : ""}Legacy profession expansion`}
                      placeholder="All expansions"
                      clearable
                      clearButtonProps={{
                        "aria-label": `Clear ${prefix ? "Population B " : ""}Legacy profession expansion`,
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
                      w={180}
                    />
                  )}
                  {params.has(prefix + "expansion") && (
                    <Text size="xs" c="dimmed">
                      This older link retains one exact profession-expansion
                      identity. Clear it to explore a whole game expansion.
                    </Text>
                  )}
                  {(!!configurations?.length ||
                    !!params.get(prefix + "configuration")) && (
                    <Select
                      label="Recorded configuration"
                      aria-label={`${prefix ? "Population B " : ""}Recorded configuration`}
                      placeholder="All recorded / unknown setups"
                      clearable
                      clearButtonProps={{
                        "aria-label": `Clear ${prefix ? "Population B " : ""}Recorded configuration`,
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
                                  "Selected variant (not in current results)",
                              },
                              ...(configurations ?? []),
                            ]
                          : (configurations ?? [])
                      }
                      w={250}
                    />
                  )}
                </Group>
                {!hideRoleItems && (
                  <Group align="end" gap="sm">
                    <ItemFilter
                      game={game}
                      label={`${prefix ? "Population B " : ""}Input item`}
                      value={params.get(prefix + "input")}
                      onChange={(value) => set("input", value)}
                    />
                    <ItemFilter
                      game={game}
                      label={`${prefix ? "Population B " : ""}Absent recorded input`}
                      value={params.get(prefix + "absentInput")}
                      onChange={(value) => set("absentInput", value)}
                    />
                    <ItemFilter
                      game={game}
                      label={`${prefix ? "Population B " : ""}Output item`}
                      value={params.get(prefix + "output")}
                      onChange={(value) => set("output", value)}
                    />
                    {supportsRetailOptions && (
                      <ItemFilter
                        game={game}
                        label={`${prefix ? "Population B " : ""}Returned item`}
                        value={params.get(prefix + "returned")}
                        onChange={(value) => set("returned", value)}
                      />
                    )}
                    <ItemFilter
                      game={game}
                      label={`${prefix ? "Population B " : ""}Any-role item`}
                      value={params.get(prefix + "item")}
                      onChange={(value) => set("item", value)}
                    />
                  </Group>
                )}
                {!hideRoleItems && (
                  <Text size="xs" c="dimmed">
                    Absent input requires a complete input record and a known
                    zero or no{" "}
                    {game.project === 18
                      ? "attributed requirement"
                      : "allocation"}{" "}
                    for that item.
                  </Text>
                )}
                {supportsRetailOptions && (
                  <>
                    <Group align="end" gap="sm">
                      <TextInput
                        label={`${prefix ? "Population B " : ""}Recorded buff spell ID`}
                        placeholder="Any"
                        defaultValue={params.get(prefix + "buff") ?? ""}
                        onBlur={(event) =>
                          set("buff", event.currentTarget.value)
                        }
                        w={180}
                      />
                      <TextInput
                        label={`${prefix ? "Population B " : ""}Absent supported buff spell ID`}
                        placeholder="Any"
                        defaultValue={params.get(prefix + "absentBuff") ?? ""}
                        onBlur={(event) =>
                          set("absentBuff", event.currentTarget.value)
                        }
                        w={225}
                      />
                      <ItemFilter
                        game={game}
                        label={`${prefix ? "Population B " : ""}Finishing item`}
                        value={params.get(prefix + "finishing")}
                        onChange={(value) => set("finishing", value)}
                      />
                      <ItemFilter
                        game={game}
                        label={`${prefix ? "Population B " : ""}Absent submitted finishing item`}
                        value={params.get(prefix + "absentFinishing")}
                        onChange={(value) => set("absentFinishing", value)}
                      />
                    </Group>
                    <Text size="xs" c="dimmed">
                      Recorded absence requires a complete supported selection
                      list; missing evidence is never treated as absent.
                    </Text>
                  </>
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
