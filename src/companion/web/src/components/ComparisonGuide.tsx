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
import { useState } from "react";
import { useSearchParams } from "react-router";
import type { ActiveGame } from "../app/game";
import { comparisonFields } from "../app/scope";
import {
  LibraryEntitiesDocument,
  WorkspaceFacetsDocument,
} from "../graphql/generated/graphql";
import { ScopeControls } from "./ScopeControls";

type Question = "characters" | "finishing" | "buff" | "periods" | "custom";
export function ComparisonGuide({
  game,
  configurations,
  finishingIds,
  buffIds,
}: {
  game: ActiveGame;
  configurations: { value: string; label: string }[];
  finishingIds: number[];
  buffIds: number[];
}) {
  const [params, setParams] = useSearchParams();
  const [question, setQuestion] = useState<Question>(
    params.get("compare") === "1" ? "custom" : "characters",
  );
  const [first, setFirst] = useState<string | null>(null);
  const [second, setSecond] = useState<string | null>(null);
  const [resource, setResource] = useState<string | null>(null);
  const [dates, setDates] = useState({ from: "", to: "", bfrom: "", bto: "" });
  const facets = useQuery(WorkspaceFacetsDocument, {
    variables: { context: game.canonicalId },
    skip: question !== "characters",
    fetchPolicy: "no-cache",
  });
  const items = useQuery(LibraryEntitiesDocument, {
    variables: {
      context: game.canonicalId,
      itemIds: finishingIds.slice(0, 100),
      recipeIds: [],
    },
    skip: question !== "finishing" || !finishingIds.length,
    fetchPolicy: "no-cache",
  });
  const compare = params.get("compare") === "1";
  function apply() {
    const next = new URLSearchParams(params);
    for (const key of comparisonFields) {
      next.delete(`b${key}`);
      const value = params.get(key);
      if (value) next.set(`b${key}`, value);
    }
    next.set("compare", "1");
    next.set("bperiod", next.get("period") ?? "90");
    for (const key of ["after", "characterOutcome", "returnItem"])
      next.delete(key);
    if (question === "characters") {
      next.set("character", first!);
      next.set("bcharacter", second!);
    }
    if (question === "finishing" || question === "buff") {
      const positive = question === "finishing" ? "finishing" : "buff";
      const absent =
        question === "finishing" ? "absentFinishing" : "absentBuff";
      for (const key of [positive, absent, `b${positive}`, `b${absent}`])
        next.delete(key);
      next.set(absent, resource!);
      next.set(`b${positive}`, resource!);
    }
    if (question === "periods") {
      next.set("period", "fixed");
      next.set("bperiod", "fixed");
      for (const [key, value] of Object.entries(dates)) next.set(key, value);
    }
    setParams(next);
  }
  const valid =
    question === "custom" ||
    (question === "characters"
      ? first && second && first !== second
      : question === "periods"
        ? Object.values(dates).every(Boolean) &&
          dates.from <= dates.to &&
          dates.bfrom <= dates.bto
        : !!resource);
  return (
    <Stack gap="sm">
      <Text>
        Choose a production question. Results compare recorded populations, not
        predicted benefits or causation.
      </Text>
      <Select
        label="What would you like to compare?"
        value={question}
        onChange={(value) => {
          setQuestion(value as Question);
          setResource(null);
        }}
        data={[
          { value: "characters", label: "Two characters" },
          ...(game.project === 1
            ? [
                {
                  value: "finishing",
                  label: "With and without a finishing reagent",
                },
                { value: "buff", label: "With and without a recorded buff" },
              ]
            : []),
          { value: "periods", label: "Before and after a change" },
          { value: "custom", label: "Custom populations" },
        ]}
        maw={420}
      />
      {(facets.error || items.error) && (
        <Alert color="red">
          Recorded choices could not be loaded.{" "}
          <Button
            variant="subtle"
            onClick={() => {
              void facets.refetch();
              void items.refetch();
            }}
          >
            Retry choices
          </Button>
        </Alert>
      )}
      {question === "characters" && (
        <Group align="end">
          {(["A", "B"] as const).map((side) => (
            <Select
              key={side}
              label={`Character ${side}`}
              value={side === "A" ? first : second}
              onChange={side === "A" ? setFirst : setSecond}
              data={
                facets.data?.game.characters.nodes.map((c) => ({
                  value: c.id,
                  label: c.name ?? "Name unavailable",
                })) ?? []
              }
            />
          ))}
        </Group>
      )}
      {question === "finishing" && (
        <Select
          label="Recorded finishing reagent"
          value={resource}
          onChange={setResource}
          data={
            items.data?.game.itemsByBlizzardIds.map((item) => ({
              value: item.id,
              label: `${item.name ?? "Name unavailable"} · #${item.blizzardId}`,
            })) ?? []
          }
          placeholder={
            finishingIds.length
              ? "Choose recorded reagent"
              : "No recorded finishing selections in this evidence"
          }
        />
      )}
      {question === "buff" && (
        <Select
          label="Supported recorded buff"
          value={resource}
          onChange={setResource}
          data={buffIds.map((id) => ({
            value: String(id),
            label: `Recorded spell ${id} · name not captured`,
          }))}
          placeholder="Choose a recorded buff"
        />
      )}
      {["finishing", "buff"].includes(question) && (
        <Text size="sm" c="dimmed">
          A: confirmed absent. B: recorded present. Missing or incomplete
          selections never count as absence. Choices reflect the first 100
          recorded setup variants.
        </Text>
      )}
      {question === "periods" && (
        <Group align="end">
          {(["from", "to", "bfrom", "bto"] as const).map((key) => (
            <TextInput
              key={key}
              type="date"
              label={`${key.startsWith("b") ? "After" : "Before"} · ${key.endsWith("from") ? "from" : "through"} (UTC)`}
              value={dates[key]}
              onChange={(event) =>
                setDates({ ...dates, [key]: event.currentTarget.value })
              }
            />
          ))}
        </Group>
      )}
      <Group>
        {(!compare || question !== "custom") && (
          <Button disabled={!valid} onClick={apply}>
            {compare ? "Apply comparison question" : "Compare setups"}
          </Button>
        )}
        {compare && (
          <Button
            variant="default"
            onClick={() => {
              const next = new URLSearchParams(params);
              for (const key of [
                ...comparisonFields.map((key) => `b${key}`),
                "compare",
                "characterOutcome",
                "returnItem",
              ])
                next.delete(key);
              setParams(next);
            }}
          >
            Remove comparison
          </Button>
        )}
      </Group>
      {(compare || question === "custom") && (
        <Accordion>
          <Accordion.Item value="custom">
            <Accordion.Control>
              Advanced · independent population filters
            </Accordion.Control>
            <Accordion.Panel>
              <Stack>
                <ScopeControls
                  game={game}
                  prefix="b"
                  configurations={configurations}
                  focusedRecipe
                />
              </Stack>
            </Accordion.Panel>
          </Accordion.Item>
        </Accordion>
      )}
    </Stack>
  );
}
