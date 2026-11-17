import { useQuery } from "@apollo/client/react";
import {
  Accordion,
  Alert,
  Anchor,
  Badge,
  Button,
  Card,
  Group,
  Loader,
  Select,
  SimpleGrid,
  Stack,
  Table,
  Tabs,
  Text,
  Title,
} from "@mantine/core";
import { useEffect, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import type { ActiveGame } from "../app/game";
import {
  analysisFilter,
  analysisGranularity,
  isCharacterOutcome,
  itemRelationFilter,
  roleFilter,
  roleLinkParams,
  type ItemRole,
} from "../app/analysisScope";
import { comparisonFields, investigationLink, scopeLabel } from "../app/scope";
import { ActivityTrend } from "../components/ActivityTrend";
import { AnalysisEvidence } from "../components/AnalysisEvidence";
import { configurationLabel } from "../components/analysisFormat";
import { ComparisonGuide } from "../components/ComparisonGuide";
import { CharacterComparison } from "../components/CharacterComparison";
import {
  coverage,
  exact,
  measuredCraftAverage,
  outcomeRows,
  rate,
  rawQuantity,
} from "../components/analysisFormat";
import { OutcomeComparison } from "../components/OutcomeComparison";
import { RequestError } from "../components/RequestError";
import {
  ItemTooltip,
  QualityBadge,
  RecipeTooltip,
} from "../components/EntityTooltip";
import { ItemFilter, ScopeControls } from "../components/ScopeControls";
import {
  ActivityInvestigationDocument,
  CharacterReturnsDocument,
  InvestigationCraftDocument,
  InvestigationCraftsDocument,
  InvestigationSignatureDocument,
  ItemInvestigationDocument,
  OverviewMetricsDocument,
  InheritedRecipeDocument,
  LibraryEntitiesDocument,
  RecipeConfigurationsDocument,
  RecipeInvestigationDocument,
  type CraftFilterInput,
  type RecipeConfigurationsQuery,
  type RecipeInvestigationQuery,
} from "../graphql/generated/graphql";
import {
  EntityActions,
  SaveInvestigation,
  useEntityPreferences,
} from "../organization";

type InvestigationKind = "activity" | "recipe" | "item" | "crafts" | "craft";
type Props = { game: ActiveGame; kind: InvestigationKind };
const retailOnlyFilters = [
  "returned",
  "buff",
  "absentBuff",
  "finishing",
  "absentFinishing",
] as const;

function withFilters(params: URLSearchParams, changes: Record<string, string>) {
  const next = new URLSearchParams(params);
  for (const [key, value] of Object.entries(changes)) next.set(key, value);
  return next;
}

function primaryScopeParams(params: URLSearchParams) {
  const next = new URLSearchParams(params);
  next.delete("compare");
  for (const field of comparisonFields) next.delete(`b${field}`);
  return next;
}

function populationParams(params: URLSearchParams, prefix: "b") {
  const next = primaryScopeParams(params);
  for (const field of comparisonFields) {
    next.delete(field);
    const value = params.get(`${prefix}${field}`);
    if (value) next.set(field, value);
  }
  return next;
}

function LinkTo({
  game,
  destination,
  params,
  children,
}: {
  game: ActiveGame;
  destination: string;
  params: URLSearchParams;
  children: React.ReactNode;
}) {
  const next =
    destination.startsWith("items/") || destination.startsWith("crafts")
      ? primaryScopeParams(params)
      : new URLSearchParams(params);
  if (destination.startsWith("recipes/"))
    next.set(
      "recipe",
      decodeURIComponent(destination.slice("recipes/".length)),
    );
  if (destination.startsWith("items/"))
    for (const key of ["item", "input", "output", "returned"]) next.delete(key);
  const link = (
    <Anchor component={Link} to={investigationLink(game, destination, next)}>
      {children}
    </Anchor>
  );
  if (destination.startsWith("items/"))
    return (
      <ItemTooltip
        game={game}
        id={decodeURIComponent(destination.slice("items/".length))}
      >
        {link}
      </ItemTooltip>
    );
  if (destination.startsWith("recipes/"))
    return (
      <RecipeTooltip
        game={game}
        id={decodeURIComponent(destination.slice("recipes/".length))}
      >
        {link}
      </RecipeTooltip>
    );
  return link;
}

function Quantity({
  measure,
}: {
  measure: {
    quantity?: string | null;
    attempts: string;
    measuredAttempts: string;
    incompleteAttempts: string;
  };
}) {
  return (
    <>
      {measure.quantity == null ? (
        <Text c="dimmed">Quantity not recorded</Text>
      ) : (
        <Text fw={600}>{exact(measure.quantity)}</Text>
      )}
      <details className="quantity-evidence">
        <summary>
          {BigInt(measure.incompleteAttempts) > 0n
            ? "Partial evidence"
            : "Measured evidence"}
        </summary>
        <Text size="xs" c="dimmed">
          {coverage(measure)}. Known quantities are included even when the
          collection is incomplete; incomplete averages remain unavailable.
        </Text>
      </details>
    </>
  );
}

function ActivityTotals({
  game,
  filter,
  signature,
  refresh,
}: {
  game: ActiveGame;
  filter: CraftFilterInput;
  signature: string;
  refresh: () => void;
}) {
  const { data, error, loading } = useQuery(OverviewMetricsDocument, {
    variables: { context: game.canonicalId, filter },
    fetchPolicy: "no-cache",
  });
  if (error) return <RequestError error={error} retry={refresh} />;
  if (loading) return <Text size="sm">Reading production totals…</Text>;
  if (!data || data.analysis.signature !== signature)
    return (
      <Alert color="yellow">
        History changed while reading totals.{" "}
        <Button variant="subtle" onClick={refresh}>
          Refresh activity
        </Button>
      </Alert>
    );
  const metrics = data.analysis.metrics;
  return (
    <>
      <Card withBorder>
        <Text size="sm">Actual output</Text>
        <Text className="metric-value">
          {exact(metrics.production.quantity)}
        </Text>
        <Text size="xs" c="dimmed">
          Includes Multicraft bonus.{" "}
          {BigInt(metrics.production.incompleteAttempts) > 0n
            ? "Partial recorded quantity."
            : "Complete output observations."}
        </Text>
      </Card>
      {game.project === 1 && data.analysis.supportsReturns && (
        <>
          {metrics.concentration && (
            <Card withBorder>
              <Text size="sm">Concentration spent</Text>
              <Text className="metric-value">
                {exact(metrics.concentration.total)}
              </Text>
              <Text size="xs" c="dimmed">
                {exact(metrics.concentration.observedAttempts)} attempts
                measured
              </Text>
            </Card>
          )}
          {metrics.multicraft && (
            <Card withBorder>
              <Text size="sm">Multicraft bonus output</Text>
              <Text className="metric-value">
                {exact(metrics.multicraft.total)}
              </Text>
              <Text size="xs" c="dimmed">
                Already included in actual output
              </Text>
            </Card>
          )}
          {metrics.resourcefulness && (
            <Card withBorder>
              <Text size="sm">Resourcefulness outcomes</Text>
              <Text className="metric-value">
                {exact(metrics.resourcefulness.positiveAttempts)}
              </Text>
              <Text size="xs" c="dimmed">
                {rate(metrics.resourcefulness) ?? "Not measured"}
              </Text>
            </Card>
          )}
        </>
      )}
    </>
  );
}

function Truncated({ value }: { value: boolean }) {
  return (
    value && (
      <Alert color="yellow">
        Only the first 100 ranked results are shown. Displayed rows are not a
        total for this population.
      </Alert>
    )
  );
}

function Ranking({
  game,
  params,
  heading,
  entries,
  destination,
  role,
  hiddenIds,
  limit,
}: {
  game: ActiveGame;
  params: URLSearchParams;
  heading: string;
  destination: "recipes" | "items";
  role?: "input" | "output" | "returned";
  hiddenIds?: ReadonlySet<string>;
  limit?: number;
  entries: {
    nodes: readonly {
      id?: string | null;
      name?: string | null;
      blizzardId?: number | null;
      measure: {
        quantity?: string | null;
        attempts: string;
        measuredAttempts: string;
        incompleteAttempts: string;
      };
    }[];
    truncated: boolean;
  };
}) {
  const shown = entries.nodes.filter(
    (row) => !row.id || !hiddenIds?.has(row.id),
  );
  return (
    <Stack gap="xs">
      <Title order={3}>{heading}</Title>
      {!shown.length && (
        <Text c="dimmed">
          {entries.nodes.length
            ? "Ranked entries are hidden in your library; their contributions remain in analytical totals."
            : "No recorded contributions in this population."}
        </Text>
      )}
      {!!shown.length && (
        <Table.ScrollContainer minWidth={500}>
          <Table striped highlightOnHover withTableBorder>
            <Table.Thead>
              <Table.Tr>
                <Table.Th>Recorded entity</Table.Th>
                <Table.Th>Quantity and coverage</Table.Th>
              </Table.Tr>
            </Table.Thead>
            <Table.Tbody>
              {shown.slice(0, limit).map((row, i) => (
                <Table.Tr key={row.id ?? i}>
                  <Table.Td>
                    {row.id ? (
                      <LinkTo
                        game={game}
                        destination={`${destination}/${encodeURIComponent(row.id)}`}
                        params={params}
                      >
                        {row.name ??
                          (row.blizzardId != null
                            ? `Item ${row.blizzardId} · name unavailable`
                            : `Unnamed ${destination === "recipes" ? "recipe" : "item"}`)}
                      </LinkTo>
                    ) : (
                      (row.name ?? "Unknown")
                    )}
                    {row.name && row.blizzardId != null && (
                      <Text size="xs" c="dimmed">
                        Item #{row.blizzardId}
                      </Text>
                    )}
                  </Table.Td>
                  <Table.Td>
                    <Quantity measure={row.measure} />
                  </Table.Td>
                </Table.Tr>
              ))}
            </Table.Tbody>
          </Table>
        </Table.ScrollContainer>
      )}
      {!limit && <Truncated value={entries.truncated} />}
      {limit && shown.length > limit && (
        <Anchor
          component={Link}
          to={investigationLink(game, destination, params)}
        >
          View all {destination === "items" ? "items" : "recipes"}
        </Anchor>
      )}
      {role && (
        <Text size="xs" c="dimmed">
          Open an item for separate output, commitment and return roles.
        </Text>
      )}
    </Stack>
  );
}

type BreakdownMeasure = {
  attempts: string;
  measuredAttempts: string;
  incompleteAttempts: string;
  quantity: string | null;
};
type BreakdownEntry = {
  key: string;
  label: string;
  itemId?: string;
  blizzardId?: number;
  measure: BreakdownMeasure;
};

function MeasuredBreakdown({
  game,
  params,
  title,
  left,
  right,
  detail,
}: {
  game: ActiveGame;
  params: URLSearchParams;
  title: string;
  left: { nodes: BreakdownEntry[]; truncated: boolean };
  right?: { nodes: BreakdownEntry[]; truncated: boolean };
  detail: string;
}) {
  const rows = new Map(
    [...left.nodes, ...(right?.nodes ?? [])].map((row) => [row.key, row]),
  );
  function cell(row: BreakdownEntry | undefined, truncated: boolean) {
    if (!row)
      return (
        <Text c="dimmed">
          {truncated
            ? "Not shown in first 100 rows"
            : "No recorded row for this population"}
        </Text>
      );
    return (
      <>
        <Quantity measure={row.measure} />
        <Text size="sm">{measuredCraftAverage(row.measure)}</Text>
      </>
    );
  }
  return (
    <Stack gap="xs">
      <Title order={3}>{title}</Title>
      <Text size="sm" c="dimmed">
        {detail} Per-craft averages are shown only when the entire contributing
        measure is complete; known partial quantities are not divided by
        complete-attempt counts.
      </Text>
      {!rows.size ? (
        <Text c="dimmed">No recorded evidence in this population.</Text>
      ) : (
        <Table.ScrollContainer minWidth={right ? 700 : 480}>
          <Table striped withTableBorder>
            <Table.Thead>
              <Table.Tr>
                <Table.Th>Recorded group</Table.Th>
                <Table.Th>
                  {right ? "Population A" : "Selected population"}
                </Table.Th>
                {right && <Table.Th>Population B</Table.Th>}
              </Table.Tr>
            </Table.Thead>
            <Table.Tbody>
              {[...rows.values()].map((row) => (
                <Table.Tr key={row.key}>
                  <Table.Td>
                    {row.itemId ? (
                      <LinkTo
                        game={game}
                        destination={`items/${encodeURIComponent(row.itemId)}`}
                        params={params}
                      >
                        {row.label}
                      </LinkTo>
                    ) : (
                      row.label
                    )}
                    {row.blizzardId != null && (
                      <Text size="xs" c="dimmed">
                        Item #{row.blizzardId}
                      </Text>
                    )}
                  </Table.Td>
                  <Table.Td>
                    {cell(
                      left.nodes.find((entry) => entry.key === row.key),
                      left.truncated,
                    )}
                  </Table.Td>
                  {right && (
                    <Table.Td>
                      {cell(
                        right.nodes.find((entry) => entry.key === row.key),
                        right.truncated,
                      )}
                    </Table.Td>
                  )}
                </Table.Tr>
              ))}
            </Table.Tbody>
          </Table>
        </Table.ScrollContainer>
      )}
      {(left.truncated || right?.truncated) && <Truncated value />}
    </Stack>
  );
}

function QualityEvidence({
  game,
  params,
  left,
  right,
}: {
  game: ActiveGame;
  params: URLSearchParams;
  left: RecipeInvestigationQuery["analysis"];
  right?: RecipeInvestigationQuery["analysis"];
}) {
  function collection(result: RecipeInvestigationQuery["analysis"]) {
    return {
      nodes: result.qualities.nodes.map((row) => ({
        key: row.quality == null ? "unknown" : String(row.quality),
        label:
          row.quality == null ? "Unknown quality" : `Quality ${row.quality}`,
        measure: row.measure,
      })),
      truncated: result.qualities.truncated,
    };
  }
  return (
    <MeasuredBreakdown
      game={game}
      params={params}
      title="Output quality evidence"
      detail="Recorded output quality, not a prediction for a future attempt."
      left={collection(left)}
      right={right ? collection(right) : undefined}
    />
  );
}

function Activity({
  game,
  params,
  filter,
  refreshBounds,
}: {
  game: ActiveGame;
  params: URLSearchParams;
  filter: CraftFilterInput;
  refreshBounds: () => void;
}) {
  const preferences = useEntityPreferences(game);
  const hiddenRecipes =
    preferences.preferences
      ?.filter((item) => item.hidden && item.kind === "Recipe")
      .map((item) => item.entityId) ?? [];
  const hiddenItems =
    preferences.preferences
      ?.filter((item) => item.hidden && item.kind === "Item")
      .map((item) => item.entityId) ?? [];
  const hiddenLookup = useQuery(LibraryEntitiesDocument, {
    variables: {
      context: game.canonicalId,
      recipeIds: hiddenRecipes,
      itemIds: hiddenItems,
    },
    skip:
      !preferences.preferences ||
      (!hiddenRecipes.length && !hiddenItems.length) ||
      hiddenRecipes.length > 100 ||
      hiddenItems.length > 100,
    fetchPolicy: "no-cache",
  });
  const hiddenRecipeIds = new Set(
    hiddenLookup.data?.game.recipesByBlizzardIds.map((row) => row.id) ?? [],
  );
  const hiddenItemIds = new Set(
    hiddenLookup.data?.game.itemsByBlizzardIds.map((row) => row.id) ?? [],
  );
  const visibilityReady =
    !!preferences.error ||
    (!!preferences.preferences &&
      ((!hiddenRecipes.length && !hiddenItems.length) ||
        !!hiddenLookup.data ||
        !!hiddenLookup.error ||
        hiddenRecipes.length > 100 ||
        hiddenItems.length > 100));
  const [search, setSearch] = useSearchParams();
  const granularity = analysisGranularity(params);
  const { data, previousData, error, loading } = useQuery(
    ActivityInvestigationDocument,
    {
      variables: { context: game.canonicalId, filter, granularity },
      fetchPolicy: "network-only",
      errorPolicy: "all",
      pollInterval: ["30", "90"].includes(params.get("period") ?? "90")
        ? 0
        : 60000,
      notifyOnNetworkStatusChange: true,
    },
  );
  const result = data?.analysis ?? previousData?.analysis;
  return (
    <Stack gap="lg">
      <header>
        <Text className="eyebrow">{game.displayName} · crafting journal</Text>
        <Title>Overview</Title>
        <Text c="dimmed">
          Completed attempts, actual output and gross commitments are separate
          observations. {scopeLabel(params)}.
        </Text>
      </header>
      <ScopeControls game={game} />
      <Group justify="space-between">
        <SaveInvestigation game={game} />
        <Button variant="default" disabled={loading} onClick={refreshBounds}>
          Refresh activity
        </Button>
        <Select
          label="Time grouping"
          aria-label="Time grouping"
          w={180}
          value={granularity.toLowerCase()}
          data={[
            { value: "day", label: "Day" },
            { value: "week", label: "Week" },
            { value: "month", label: "Month" },
          ]}
          onChange={(value) => {
            if (!value) return;
            const next = new URLSearchParams(search);
            next.set("granularity", value);
            setSearch(next, { replace: true });
          }}
        />
      </Group>
      {error && <RequestError error={error} retry={refreshBounds} />}
      {loading && !result && <Loader aria-label="Loading activity" />}
      {result && (
        <>
          <SimpleGrid cols={{ base: 2, md: 3, xl: 5 }}>
            <Card withBorder>
              <Text size="sm">Completed attempts</Text>
              <Text className="metric-value">
                {exact(result.attempts.attempts)}
              </Text>
              <LinkTo game={game} destination="crafts" params={params}>
                Inspect crafts
              </LinkTo>
            </Card>
            <ActivityTotals
              game={game}
              filter={filter}
              signature={result.signature}
              refresh={refreshBounds}
            />
          </SimpleGrid>
          <ActivityTrend
            game={game}
            params={params}
            granularity={granularity.toLowerCase() as "day" | "week" | "month"}
            points={result.timeline.nodes.map((node) => ({
              date: node.start,
              craftCount: node.measure.attempts,
            }))}
          />
          <Truncated value={result.timeline.truncated} />
          <Group justify="space-between">
            <Title order={2}>Most-crafted recipes</Title>
            <Anchor
              component={Link}
              to={investigationLink(game, "recipes", params)}
            >
              View all recipes
            </Anchor>
          </Group>
          {!visibilityReady && (
            <Text size="sm">Loading library visibility preferences…</Text>
          )}
          {(hiddenLookup.error ||
            hiddenRecipes.length > 100 ||
            hiddenItems.length > 100) && (
            <Alert color="yellow">
              Visibility preferences could not be fully applied. All recorded
              results remain available; retry from the library.
            </Alert>
          )}
          {visibilityReady && (
            <>
              <Table.ScrollContainer minWidth={750}>
                <Table
                  striped
                  highlightOnHover
                  withTableBorder
                  className="analysis-table"
                >
                  <Table.Thead>
                    <Table.Tr>
                      <Table.Th>Recipe</Table.Th>
                      <Table.Th>Completed attempts</Table.Th>
                      <Table.Th>Actual production</Table.Th>
                      {game.project === 1 && result.supportsReturns && (
                        <Table.Th>Observed ingenuity</Table.Th>
                      )}
                    </Table.Tr>
                  </Table.Thead>
                  <Table.Tbody>
                    {result.recipes.nodes
                      .filter((row) => !hiddenRecipeIds.has(row.id))
                      .slice(0, 8)
                      .map((row) => (
                        <Table.Tr key={row.id}>
                          <Table.Td>
                            <LinkTo
                              game={game}
                              destination={`recipes/${encodeURIComponent(row.id)}`}
                              params={params}
                            >
                              {row.name ?? "Unnamed recipe"}
                            </LinkTo>
                          </Table.Td>
                          <Table.Td>{exact(row.outputs.attempts)}</Table.Td>
                          <Table.Td>
                            <Quantity measure={row.outputs} />
                          </Table.Td>
                          {game.project === 1 && result.supportsReturns && (
                            <Table.Td>
                              {row.ingenuity ? (
                                <>
                                  {exact(row.ingenuity.positiveAttempts)}{" "}
                                  positive /{" "}
                                  {exact(row.ingenuity.observedAttempts)}{" "}
                                  observed
                                  <Text size="xs" c="dimmed">
                                    {rate(row.ingenuity) ?? "Rate unknown"} ·{" "}
                                    {exact(row.ingenuity.unknownAttempts)}{" "}
                                    unknown
                                  </Text>
                                </>
                              ) : (
                                "Not observed"
                              )}
                            </Table.Td>
                          )}
                        </Table.Tr>
                      ))}
                  </Table.Tbody>
                </Table>
              </Table.ScrollContainer>
              {!result.recipes.nodes.length && (
                <Text c="dimmed">No completed attempts in this scope.</Text>
              )}
              {!!result.recipes.nodes.length &&
                result.recipes.nodes.every((row) =>
                  hiddenRecipeIds.has(row.id),
                ) && (
                  <Text c="dimmed">
                    Ranked recipes are hidden in your library; their attempts
                    remain in analytical totals.
                  </Text>
                )}
              <Truncated value={result.recipes.truncated} />
            </>
          )}
          <SimpleGrid cols={{ base: 1, lg: 2 }}>
            {!visibilityReady ? (
              <Text size="sm">Loading library visibility preferences…</Text>
            ) : (
              <>
                <Ranking
                  game={game}
                  params={params}
                  heading="Actual output items"
                  entries={result.outputs}
                  destination="items"
                  role="output"
                  hiddenIds={hiddenItemIds}
                  limit={8}
                />
                <Ranking
                  game={game}
                  params={params}
                  heading={result.inputMeasureLabel}
                  entries={result.inputs}
                  destination="items"
                  role="input"
                  hiddenIds={hiddenItemIds}
                  limit={8}
                />
              </>
            )}
          </SimpleGrid>
          <Accordion>
            <Accordion.Item value="reports">
              <Accordion.Control>
                More production reports & evidence
              </Accordion.Control>
              <Accordion.Panel>
                <Stack gap="lg">
                  <SimpleGrid cols={{ base: 1, lg: 2 }}>
                    {visibilityReady && (
                      <>
                        {game.project === 1 &&
                          result.supportsReturns &&
                          result.returns && (
                            <Ranking
                              game={game}
                              params={params}
                              heading="Returned materials"
                              entries={result.returns}
                              destination="items"
                              role="returned"
                              hiddenIds={hiddenItemIds}
                            />
                          )}
                      </>
                    )}
                    {game.project === 1 && (
                      <Stack gap="xs">
                        <Title order={3}>Recorded output qualities</Title>
                        {result.qualities.nodes.length ? (
                          <Table>
                            <Table.Tbody>
                              {result.qualities.nodes.map((row, index) => (
                                <Table.Tr key={index}>
                                  <Table.Td>
                                    Quality {row.quality ?? "unknown"}
                                  </Table.Td>
                                  <Table.Td>
                                    <Quantity measure={row.measure} />
                                  </Table.Td>
                                </Table.Tr>
                              ))}
                            </Table.Tbody>
                          </Table>
                        ) : (
                          <Text c="dimmed">
                            No recorded quality observations.
                          </Text>
                        )}
                        <Truncated value={result.qualities.truncated} />
                      </Stack>
                    )}
                  </SimpleGrid>
                  <Stack gap="xs">
                    <Title order={2}>Characters in this population</Title>
                    <Text size="sm" c="dimmed">
                      Observed outcomes by recorded character, not a
                      leaderboard.
                    </Text>
                    <Table.ScrollContainer minWidth={650}>
                      <Table striped withTableBorder>
                        <Table.Thead>
                          <Table.Tr>
                            <Table.Th>Character</Table.Th>
                            <Table.Th>Attempts</Table.Th>
                            <Table.Th>Production coverage</Table.Th>
                            {game.project === 1 && result.supportsReturns && (
                              <Table.Th>Ingenuity observed rate</Table.Th>
                            )}
                          </Table.Tr>
                        </Table.Thead>
                        <Table.Tbody>
                          {result.characters.nodes.map((row, i) => (
                            <Table.Tr key={row.id ?? i}>
                              <Table.Td>
                                {row.id ? (
                                  <LinkTo
                                    game={game}
                                    params={withFilters(params, {
                                      character: row.id,
                                    })}
                                    destination="crafts"
                                  >
                                    {row.name ?? "Unnamed character"}
                                  </LinkTo>
                                ) : (
                                  (row.name ?? "Unknown")
                                )}
                              </Table.Td>
                              <Table.Td>{exact(row.measure.attempts)}</Table.Td>
                              <Table.Td>
                                {row.metrics
                                  ? coverage(row.metrics.production)
                                  : "Unknown"}
                              </Table.Td>
                              {game.project === 1 && result.supportsReturns && (
                                <Table.Td>
                                  {row.metrics?.ingenuity
                                    ? (rate(row.metrics.ingenuity) ??
                                      "Not observed")
                                    : "Unknown"}
                                </Table.Td>
                              )}
                            </Table.Tr>
                          ))}
                        </Table.Tbody>
                      </Table>
                    </Table.ScrollContainer>
                    <Truncated value={result.characters.truncated} />
                  </Stack>
                  <Text size="sm" c="dimmed">
                    Configuration evidence:{" "}
                    {exact(result.configurationCoverage.recordedAttempts)}{" "}
                    attempts with recorded variants ·{" "}
                    {exact(result.configurationCoverage.emptyAttempts)}{" "}
                    explicitly empty ·{" "}
                    {exact(result.configurationCoverage.unknownAttempts)}{" "}
                    unknown.
                  </Text>
                </Stack>
              </Accordion.Panel>
            </Accordion.Item>
          </Accordion>
          {preferences.preferences?.some((item) => item.hidden) && (
            <Text size="xs" c="dimmed">
              Hidden library items remain included in all analytical totals and
              rankings.
            </Text>
          )}
        </>
      )}
    </Stack>
  );
}

function SignatureNotice({
  game,
  filter,
  signature,
  refresh,
}: {
  game: ActiveGame;
  filter: CraftFilterInput;
  signature: string;
  refresh: () => void;
}) {
  const { data, error, refetch } = useQuery(InvestigationSignatureDocument, {
    variables: { context: game.canonicalId, filter },
    fetchPolicy: "network-only",
    pollInterval: 30000,
  });
  if (error)
    return (
      <Alert color="yellow" title="Cannot check for new evidence">
        The displayed investigation is retained, but its freshness could not be
        checked.{" "}
        <Button variant="light" size="xs" onClick={() => void refetch()}>
          Retry freshness check
        </Button>
      </Alert>
    );
  return data?.analysisSignature && data.analysisSignature !== signature ? (
    <Alert color="yellow" title="Relevant history changed">
      New or enriched evidence may affect these results. The displayed
      investigation is retained until you refresh. Crafts and separate queries
      are not a frozen snapshot.{" "}
      <Button variant="light" size="xs" onClick={refresh}>
        Refresh investigation
      </Button>
    </Alert>
  ) : null;
}

function Configurations({
  game,
  params,
  result,
  choices,
}: {
  game: ActiveGame;
  params: URLSearchParams;
  result: RecipeConfigurationsQuery["analysis"];
  choices: { value: string; label: string }[];
}) {
  return (
    <Stack gap="xs">
      <Title order={2}>Recorded configurations</Title>
      <Text size="sm" c="dimmed">
        Each row is one exact recorded evidence variant. Unknown configurations
        are not an observed empty setup. Counts can overlap when a craft has
        more than one variant.
      </Text>
      <Text size="sm" c="dimmed">
        {exact(result.configurationCoverage.recordedAttempts)} attempts with
        variants · {exact(result.configurationCoverage.emptyAttempts)}{" "}
        explicitly empty · {exact(result.configurationCoverage.unknownAttempts)}{" "}
        unknown.
      </Text>
      {!result.configurations.nodes.length && (
        <Text c="dimmed">
          No recorded configuration evidence in this population.
        </Text>
      )}
      <Accordion variant="separated">
        {result.configurations.nodes.map((row) => (
          <Accordion.Item key={row.id} value={row.id}>
            <Accordion.Control>
              {choices.find((choice) => choice.value === row.id)?.label ??
                "Recorded setup"}{" "}
              · {exact(row.measure.attempts)} attempts ·{" "}
              {coverage(row.metrics.production)}
            </Accordion.Control>
            <Accordion.Panel>
              <Stack>
                <Group>
                  <Button
                    size="xs"
                    variant="light"
                    component={Link}
                    to={investigationLink(
                      game,
                      "crafts",
                      primaryScopeParams(params),
                      {
                        configuration: row.id,
                      },
                    )}
                  >
                    Inspect matching crafts
                  </Button>
                  <Button
                    size="xs"
                    variant="light"
                    component={Link}
                    to={investigationLink(
                      game,
                      `recipes/${encodeURIComponent(params.get("recipe") ?? "")}`,
                      params,
                      { configuration: row.id },
                    )}
                  >
                    Filter population
                  </Button>
                </Group>
                <OutcomeComparison
                  left={outcomeRows(
                    row.measure.attempts,
                    row.metrics,
                    game.project === 1 && result.supportsReturns,
                  )}
                />
                <AnalysisEvidence
                  evidence={row.evidence}
                  available={row.evidenceAvailable}
                />
              </Stack>
            </Accordion.Panel>
          </Accordion.Item>
        ))}
      </Accordion>
      <Truncated value={result.configurations.truncated} />
    </Stack>
  );
}

function Recipe({
  game,
  params,
  filter,
  id,
  second,
  refreshBounds,
}: {
  game: ActiveGame;
  params: URLSearchParams;
  filter: CraftFilterInput;
  id: string;
  second?: CraftFilterInput;
  refreshBounds: () => void;
}) {
  const compare = params.get("compare") === "1";
  const returnItem = params.get("returnItem");
  const compareReturns =
    compare &&
    game.project === 1 &&
    params.get("characterOutcome") === "returns" &&
    !!returnItem;
  const first = useQuery(RecipeInvestigationDocument, {
    variables: { context: game.canonicalId, id, filter },
    fetchPolicy: "no-cache",
    errorPolicy: "all",
    notifyOnNetworkStatusChange: true,
  });
  const other = useQuery(RecipeInvestigationDocument, {
    variables: { context: game.canonicalId, id, filter: second },
    skip: !compare,
    fetchPolicy: "no-cache",
    errorPolicy: "all",
    notifyOnNetworkStatusChange: true,
  });
  const configsFirst = useQuery(RecipeConfigurationsDocument, {
    variables: { context: game.canonicalId, filter },
    fetchPolicy: "no-cache",
    errorPolicy: "all",
    notifyOnNetworkStatusChange: true,
  });
  const configsOther = useQuery(RecipeConfigurationsDocument, {
    variables: { context: game.canonicalId, filter: second },
    skip: !compare,
    fetchPolicy: "no-cache",
    errorPolicy: "all",
    notifyOnNetworkStatusChange: true,
  });
  const returnsFirst = useQuery(CharacterReturnsDocument, {
    variables: { context: game.canonicalId, filter, item: returnItem ?? "" },
    skip: !compareReturns,
    fetchPolicy: "no-cache",
    errorPolicy: "all",
  });
  const returnsOther = useQuery(CharacterReturnsDocument, {
    variables: {
      context: game.canonicalId,
      filter: second,
      item: returnItem ?? "",
    },
    skip: !compareReturns,
    fetchPolicy: "no-cache",
    errorPolicy: "all",
  });
  const left = first.data?.analysis;
  const right = compare ? other.data?.analysis : undefined;
  const leftConfigs =
    left && configsFirst.data?.analysis.signature === left.signature
      ? configsFirst.data.analysis
      : undefined;
  const rightConfigs =
    right && configsOther.data?.analysis.signature === right.signature
      ? configsOther.data.analysis
      : undefined;
  const [search, setSearch] = useSearchParams();
  const configurations = [
    ...(leftConfigs?.configurations.nodes ?? []),
    ...(rightConfigs?.configurations.nodes ?? []),
  ];
  const choices = [
    ...new Map(configurations.map((row) => [row.id, row])).values(),
  ]
    .sort((a, b) => a.id.localeCompare(b.id))
    .map((row) => ({
      value: row.id,
      label: configurationLabel(row.id, row.evidence),
    }));
  const selectedCharacterOutcome = params.get("characterOutcome");
  const refresh = refreshBounds;
  return (
    <Stack gap="lg">
      <header>
        <Text className="eyebrow">
          {game.displayName} · recipe investigation
        </Text>
        <Title>
          {first.data?.recipe?.name ??
            (first.loading ? "Investigating recipe…" : "Unnamed recipe")}
        </Title>
        <Text c="dimmed">
          {[
            ...new Set(
              [
                first.data?.recipe?.profession?.name ?? "Profession unknown",
                first.data?.recipe?.expansion?.name,
              ].filter(Boolean),
            ),
          ].join(" · ")}{" "}
          · {scopeLabel(params)}
        </Text>
        {first.data?.recipe && (
          <EntityActions
            game={game}
            kind="Recipe"
            blizzardId={first.data.recipe.blizzardId}
          />
        )}
      </header>
      <ScopeControls game={game} focusedRecipe configurations={choices} />
      <Group>
        <Button
          variant="default"
          disabled={
            first.loading ||
            other.loading ||
            configsFirst.loading ||
            configsOther.loading
          }
          onClick={refresh}
        >
          Refresh investigation
        </Button>
      </Group>
      {params.has("after") ? (
        <Text size="sm" c="dimmed">
          Return to the newest craft page to save this scope without a transient
          page cursor.
        </Text>
      ) : (
        <SaveInvestigation game={game} />
      )}
      {first.error && <RequestError error={first.error} retry={refresh} />}
      {other.error && <RequestError error={other.error} retry={refresh} />}
      {configsFirst.error && (
        <RequestError error={configsFirst.error} retry={refresh} />
      )}
      {configsOther.error && (
        <RequestError error={configsOther.error} retry={refresh} />
      )}
      {(left?.signature &&
        configsFirst.data?.analysis.signature &&
        !leftConfigs) ||
      (right?.signature &&
        configsOther.data?.analysis.signature &&
        !rightConfigs) ? (
        <Alert color="yellow" title="Recorded setup evidence changed">
          The bounded recipe and configuration reads came from different history
          versions. Setup comparisons are withheld until you refresh the
          investigation.
        </Alert>
      ) : null}
      {((first.loading && !left) || (compare && other.loading && !right)) && (
        <Loader aria-label="Loading recipe investigation" />
      )}
      {first.data && !first.data.recipe && (
        <Alert color="yellow">
          No recipe has this identity in the selected game. The filtered attempt
          population is shown separately if available.
        </Alert>
      )}
      {left && (
        <>
          <SignatureNotice
            game={game}
            filter={filter}
            signature={left.signature}
            refresh={refresh}
          />
          {right && second && (
            <SignatureNotice
              game={game}
              filter={second}
              signature={right.signature}
              refresh={refresh}
            />
          )}
          <SimpleGrid cols={{ base: 2, sm: 3 }}>
            <Card withBorder>
              <Text size="sm">Completed crafts</Text>
              <Text className="metric-value">
                {exact(left.attempts.attempts)}
              </Text>
            </Card>
            <Card withBorder>
              <Text size="sm">Actual output</Text>
              <Quantity
                measure={
                  left.recipes.nodes.find((row) => row.id === id)?.outputs ?? {
                    ...left.attempts,
                    quantity: null,
                  }
                }
              />
            </Card>
          </SimpleGrid>
          <Tabs
            defaultValue={compare ? "compare" : "overview"}
            keepMounted={false}
          >
            <Tabs.List aria-label="Recipe sections">
              <Tabs.Tab value="overview">Overview</Tabs.Tab>
              <Tabs.Tab value="statistics">Statistics</Tabs.Tab>
              <Tabs.Tab value="crafts">Craft History</Tabs.Tab>
              <Tabs.Tab value="reagents">Reagents</Tabs.Tab>
              <Tabs.Tab value="compare">Compare setups</Tabs.Tab>
            </Tabs.List>
            <Tabs.Panel value="statistics">
              <Stack gap="md">
                <Title order={2}>Outcome evidence</Title>
                <RecipeOutcomes
                  id={id}
                  left={left}
                  right={right}
                  retail={game.project === 1}
                />
              </Stack>
            </Tabs.Panel>
            <Tabs.Panel value="overview">
              <Stack gap="lg">
                <Title order={2}>Recipe activity over time</Title>
                <SimpleGrid cols={{ base: 1, lg: right ? 2 : 1 }}>
                  <Stack gap="xs">
                    {right && (
                      <Title order={3}>Population A recipe activity</Title>
                    )}
                    <ActivityTrend
                      game={game}
                      params={withFilters(primaryScopeParams(params), {
                        recipe: id,
                      })}
                      points={left.timeline.nodes.map((node) => ({
                        date: node.start,
                        craftCount: node.measure.attempts,
                      }))}
                    />
                    <Truncated value={left.timeline.truncated} />
                  </Stack>
                  {right && (
                    <Stack gap="xs">
                      <Title order={3}>Population B recipe activity</Title>
                      <ActivityTrend
                        game={game}
                        params={withFilters(populationParams(params, "b"), {
                          recipe: id,
                        })}
                        points={right.timeline.nodes.map((node) => ({
                          date: node.start,
                          craftCount: node.measure.attempts,
                        }))}
                      />
                      <Truncated value={right.timeline.truncated} />
                    </Stack>
                  )}
                </SimpleGrid>
                <Ranking
                  game={game}
                  params={withFilters(params, { recipe: id })}
                  heading="Actual output items"
                  entries={left.outputs}
                  destination="items"
                  role="output"
                />
                {game.project === 1 && (
                  <QualityEvidence
                    game={game}
                    params={params}
                    left={left}
                    right={right}
                  />
                )}
              </Stack>
            </Tabs.Panel>
            <Tabs.Panel value="reagents">
              <SimpleGrid cols={{ base: 1, lg: 2 }}>
                <Ranking
                  game={game}
                  params={withFilters(params, { recipe: id })}
                  heading="Actual output items"
                  entries={left.outputs}
                  destination="items"
                  role="output"
                />
                <Ranking
                  game={game}
                  params={withFilters(params, { recipe: id })}
                  heading={left.inputMeasureLabel}
                  entries={left.inputs}
                  destination="items"
                  role="input"
                />
                {game.project === 1 && left.supportsReturns && left.returns && (
                  <MeasuredBreakdown
                    game={game}
                    params={withFilters(params, { recipe: id })}
                    title="Returned material quantities"
                    detail="Each row covers attempts containing this reagent; returns remain separate from gross allocation."
                    left={{
                      nodes: left.returns.nodes.map((row, i) => ({
                        key: row.id ?? `unidentified-${i}`,
                        label:
                          row.name ??
                          (row.blizzardId != null
                            ? `Item ${row.blizzardId} · name unavailable`
                            : "Item · name unavailable"),
                        itemId: row.id ?? undefined,
                        blizzardId: row.name
                          ? (row.blizzardId ?? undefined)
                          : undefined,
                        measure: row.measure,
                      })),
                      truncated: left.returns.truncated,
                    }}
                    right={
                      right?.returns
                        ? {
                            nodes: right.returns.nodes.map((row, i) => ({
                              key: row.id ?? `unidentified-${i}`,
                              label:
                                row.name ??
                                (row.blizzardId != null
                                  ? `Item ${row.blizzardId} · name unavailable`
                                  : "Item · name unavailable"),
                              itemId: row.id ?? undefined,
                              blizzardId: row.name
                                ? (row.blizzardId ?? undefined)
                                : undefined,
                              measure: row.measure,
                            })),
                            truncated: right.returns.truncated,
                          }
                        : undefined
                    }
                  />
                )}
              </SimpleGrid>
            </Tabs.Panel>
            <Tabs.Panel value="compare">
              <Stack gap="lg">
                <ComparisonGuide
                  game={game}
                  configurations={choices}
                  finishingIds={[
                    ...new Set(
                      configurations.flatMap(
                        (row) =>
                          row.evidence.finishingReagents?.flatMap((entry) =>
                            entry.itemId == null ? [] : [entry.itemId],
                          ) ?? [],
                      ),
                    ),
                  ]}
                  buffIds={[
                    ...new Set(
                      configurations.flatMap(
                        (row) =>
                          row.evidence.buffs?.flatMap((entry) =>
                            entry.spellId == null ? [] : [entry.spellId],
                          ) ?? [],
                      ),
                    ),
                  ]}
                />
                {right && (
                  <RecipeOutcomes
                    id={id}
                    left={left}
                    right={right}
                    retail={game.project === 1}
                  />
                )}
                <Accordion>
                  <Accordion.Item value="setups">
                    <Accordion.Control>
                      Inspect recorded setup variants
                    </Accordion.Control>
                    <Accordion.Panel>
                      {!leftConfigs && configsFirst.loading && (
                        <Loader aria-label="Loading recorded configurations" />
                      )}
                      {leftConfigs && (
                        <Configurations
                          game={game}
                          params={withFilters(params, { recipe: id })}
                          result={leftConfigs}
                          choices={choices}
                        />
                      )}
                    </Accordion.Panel>
                  </Accordion.Item>
                </Accordion>
                {right && rightConfigs && leftConfigs && (
                  <Stack gap="xs">
                    <Title order={2}>Recorded setup differences</Title>
                    <Text size="sm" c="dimmed">
                      Select one exact recorded configuration in each population
                      to inspect its supported setup side by side. Missing
                      fields are unknown, not absent; variants and sample sizes
                      may differ for unrelated reasons.
                    </Text>
                    <SimpleGrid cols={{ base: 1, lg: 2 }}>
                      {(["A", "B"] as const).map((population) => {
                        const selected = params.get(
                          population === "A"
                            ? "configuration"
                            : "bconfiguration",
                        );
                        const result =
                          population === "A" ? leftConfigs : rightConfigs;
                        const variant = result.configurations.nodes.find(
                          (row) => row.id === selected,
                        );
                        return (
                          <Card key={population} withBorder>
                            <Stack gap="xs">
                              <Title order={3}>
                                Population {population} setup
                              </Title>
                              {!selected ? (
                                <Text c="dimmed">
                                  No single recorded setup selected; the
                                  population can include recorded, empty and
                                  unknown configuration evidence.
                                </Text>
                              ) : !variant ? (
                                <Text c="dimmed">
                                  The selected variant is not present in the
                                  first 100 rows for this population.
                                </Text>
                              ) : (
                                <>
                                  <Text>
                                    {coverage(variant.metrics.production)}
                                  </Text>
                                  <AnalysisEvidence
                                    evidence={variant.evidence}
                                    available={variant.evidenceAvailable}
                                  />
                                </>
                              )}
                            </Stack>
                          </Card>
                        );
                      })}
                    </SimpleGrid>
                  </Stack>
                )}
                <Title order={2}>Characters & decisions</Title>
                <Text size="sm" c="dimmed">
                  Recorded character populations are observational. Contrast
                  sample sizes and measured coverage before drawing conclusions.
                </Text>
                <Table.ScrollContainer minWidth={700}>
                  <Table striped withTableBorder>
                    <Table.Thead>
                      <Table.Tr>
                        <Table.Th>Character</Table.Th>
                        <Table.Th>Attempts</Table.Th>
                        <Table.Th>Actual production</Table.Th>
                        {game.project === 1 && left.supportsReturns && (
                          <Table.Th>Ingenuity rate</Table.Th>
                        )}
                        <Table.Th>Evidence</Table.Th>
                      </Table.Tr>
                    </Table.Thead>
                    <Table.Tbody>
                      {left.characters.nodes.map((row, i) => (
                        <Table.Tr key={row.id ?? i}>
                          <Table.Td>{row.name ?? "Unnamed character"}</Table.Td>
                          <Table.Td>{exact(row.measure.attempts)}</Table.Td>
                          <Table.Td>
                            {row.metrics ? (
                              <Quantity measure={row.metrics.production} />
                            ) : (
                              "Not measured"
                            )}
                          </Table.Td>
                          {game.project === 1 && left.supportsReturns && (
                            <Table.Td>
                              {row.metrics?.ingenuity
                                ? (rate(row.metrics.ingenuity) ??
                                  "Not observed")
                                : "Unknown"}
                            </Table.Td>
                          )}
                          <Table.Td>
                            {row.id && (
                              <LinkTo
                                game={game}
                                destination="crafts"
                                params={withFilters(params, {
                                  character: row.id,
                                  recipe: id,
                                })}
                              >
                                Inspect crafts
                              </LinkTo>
                            )}
                          </Table.Td>
                        </Table.Tr>
                      ))}
                    </Table.Tbody>
                  </Table>
                </Table.ScrollContainer>
                <Truncated value={left.characters.truncated} />
                {compareReturns &&
                  (returnsFirst.error || returnsOther.error) && (
                    <Alert
                      color="red"
                      title="Returned material evidence could not be loaded"
                    >
                      <Button
                        variant="light"
                        size="xs"
                        onClick={() => {
                          void returnsFirst.refetch();
                          void returnsOther.refetch();
                        }}
                      >
                        Retry
                      </Button>
                    </Alert>
                  )}
                {compareReturns &&
                  (returnsFirst.loading || returnsOther.loading) && (
                    <Text size="sm">Loading returned material evidence…</Text>
                  )}
                {compareReturns &&
                  right &&
                  !returnsFirst.loading &&
                  !returnsOther.loading &&
                  !returnsFirst.error &&
                  !returnsOther.error &&
                  ((returnsFirst.data &&
                    returnsFirst.data.analysis.signature !== left.signature) ||
                    (returnsOther.data &&
                      returnsOther.data.analysis.signature !==
                        right.signature)) && (
                    <Alert
                      color="yellow"
                      title="Returned material evidence changed"
                    >
                      Refresh the investigation before comparing these results.
                      <Button variant="light" size="xs" onClick={refresh}>
                        Refresh investigation
                      </Button>
                    </Alert>
                  )}
                {right && (
                  <CharacterComparison
                    left={left.characters}
                    right={right.characters}
                    attributedRequirements={game.project === 18}
                    includeRetailOutcomes={
                      game.project === 1 && left.supportsReturns
                    }
                    metric={
                      isCharacterOutcome(selectedCharacterOutcome)
                        ? selectedCharacterOutcome
                        : game.project === 1
                          ? "ingenuity"
                          : "production"
                    }
                    onMetricChange={(value) => {
                      const next = new URLSearchParams(search);
                      next.set("characterOutcome", value);
                      if (value !== "returns") next.delete("returnItem");
                      setSearch(next, { replace: true });
                    }}
                    returnItemControl={
                      <ItemFilter
                        game={game}
                        label="Returned material to compare"
                        value={returnItem}
                        onChange={(value) => {
                          const next = new URLSearchParams(search);
                          if (value) next.set("returnItem", value);
                          else next.delete("returnItem");
                          setSearch(next, { replace: true });
                        }}
                      />
                    }
                    leftReturns={
                      !returnsFirst.loading &&
                      !returnsFirst.error &&
                      returnsFirst.data?.analysis.signature === left.signature
                        ? returnsFirst.data.analysis.characters
                        : undefined
                    }
                    rightReturns={
                      !returnsOther.loading &&
                      !returnsOther.error &&
                      returnsOther.data?.analysis.signature === right.signature
                        ? returnsOther.data.analysis.characters
                        : undefined
                    }
                    resourceComparison={
                      (!!params.get("absentFinishing") &&
                        params.get("absentFinishing") ===
                          params.get("bfinishing") &&
                        !params.has("finishing") &&
                        !params.has("babsentFinishing")) ||
                      (!!params.get("absentInput") &&
                        params.get("absentInput") === params.get("binput") &&
                        !params.has("babsentInput") &&
                        ![
                          "finishing",
                          "absentFinishing",
                          "bfinishing",
                          "babsentFinishing",
                        ].some((key) => params.has(key)))
                    }
                  />
                )}
                {right && (
                  <Stack gap="xs">
                    <Title order={3}>Population B characters</Title>
                    <Table.ScrollContainer minWidth={600}>
                      <Table striped withTableBorder>
                        <Table.Thead>
                          <Table.Tr>
                            <Table.Th>Character</Table.Th>
                            <Table.Th>Attempts</Table.Th>
                            <Table.Th>Production coverage</Table.Th>
                            {game.project === 1 && right.supportsReturns && (
                              <Table.Th>Ingenuity observed rate</Table.Th>
                            )}
                            <Table.Th>Evidence</Table.Th>
                          </Table.Tr>
                        </Table.Thead>
                        <Table.Tbody>
                          {right.characters.nodes.map((row, i) => (
                            <Table.Tr key={row.id ?? i}>
                              <Table.Td>
                                {row.name ?? "Unnamed character"}
                              </Table.Td>
                              <Table.Td>{exact(row.measure.attempts)}</Table.Td>
                              <Table.Td>
                                {row.metrics
                                  ? coverage(row.metrics.production)
                                  : "Unknown"}
                              </Table.Td>
                              {game.project === 1 && right.supportsReturns && (
                                <Table.Td>
                                  {row.metrics?.ingenuity
                                    ? (rate(row.metrics.ingenuity) ??
                                      "Not observed")
                                    : "Unknown"}
                                </Table.Td>
                              )}
                              <Table.Td>
                                {row.id && (
                                  <LinkTo
                                    game={game}
                                    destination="crafts"
                                    params={withFilters(
                                      populationParams(params, "b"),
                                      { character: row.id, recipe: id },
                                    )}
                                  >
                                    Inspect B crafts
                                  </LinkTo>
                                )}
                              </Table.Td>
                            </Table.Tr>
                          ))}
                        </Table.Tbody>
                      </Table>
                    </Table.ScrollContainer>
                    <Truncated value={right.characters.truncated} />
                  </Stack>
                )}
              </Stack>
            </Tabs.Panel>
            <Tabs.Panel value="crafts">
              <Stack gap="md">
                <Title order={2}>Contributing crafts</Title>
                <Crafts
                  game={game}
                  params={withFilters(params, { recipe: id })}
                  filter={filter}
                  refreshBounds={refreshBounds}
                  embedded
                />
              </Stack>
            </Tabs.Panel>
          </Tabs>
        </>
      )}
    </Stack>
  );
}

function RecipeOutcomes({
  id,
  left,
  right,
  retail,
}: {
  id: string;
  left: RecipeInvestigationQuery["analysis"];
  right?: RecipeInvestigationQuery["analysis"];
  retail: boolean;
}) {
  function rows(result: typeof left) {
    const recipe = result.recipes.nodes.find((row) => row.id === id);
    return [
      { label: "Completed attempts", value: exact(result.attempts.attempts) },
      ...(recipe
        ? outcomeRows(
            recipe.outputs.attempts,
            {
              production: recipe.outputs,
              ingenuity: recipe.ingenuity,
              resourcefulness: recipe.resourcefulness,
              multicraft: recipe.multicraft,
              concentration: recipe.concentration,
              refund: recipe.refund,
            },
            retail && result.supportsReturns,
          )
        : []),
    ];
  }
  return (
    <>
      <OutcomeComparison
        left={rows(left)}
        right={right ? rows(right) : undefined}
      />
      {(left.recipes.truncated || right?.recipes.truncated) && (
        <Truncated value />
      )}
      {retail && left.supportsReturns && (
        <Text size="sm" c="dimmed">
          Rates use observed denominators, not all attempts. Unknown evidence is
          not a zero outcome. Actual output quantities already include any
          Multicraft bonus.
        </Text>
      )}
    </>
  );
}

function Item({
  game,
  params,
  id,
  now,
  refreshBounds,
}: {
  game: ActiveGame;
  params: URLSearchParams;
  id: string;
  now: Date;
  refreshBounds: () => void;
}) {
  const { data, loading, error } = useQuery(ItemInvestigationDocument, {
    variables: {
      context: game.canonicalId,
      id,
      relations: itemRelationFilter(params, id, now),
      output: roleFilter(params, id, "output", now),
      input: roleFilter(params, id, "input", now),
      returned: roleFilter(params, id, "returned", now),
      retail: game.project === 1,
    },
    fetchPolicy: "network-only",
    errorPolicy: "all",
    notifyOnNetworkStatusChange: true,
  });
  const item = data?.item;
  const inherited = useQuery(InheritedRecipeDocument, {
    variables: { context: game.canonicalId, id: params.get("recipe") ?? "" },
    skip: !params.has("recipe"),
    fetchPolicy: "no-cache",
  });
  const roles: { role: ItemRole; title: string }[] = data
    ? [
        { role: "output", title: "Actual output" },
        { role: "input", title: data.committed.inputMeasureLabel },
        ...(game.project === 1 && data.returned?.supportsReturns
          ? [{ role: "returned" as const, title: "Recorded returns" }]
          : []),
      ]
    : [];
  return (
    <Stack gap="lg">
      <header>
        <Text className="eyebrow">{game.displayName} · item investigation</Text>
        <Title>
          {item?.name ??
            (loading
              ? "Investigating item…"
              : item
                ? `Item ${item.blizzardId} · name unavailable`
                : "Item unavailable")}
        </Title>
        {item && (
          <Text size="sm" c="dimmed">
            Item #{item.blizzardId}
            <QualityBadge quality={item.quality} />
          </Text>
        )}
        <Text c="dimmed">
          Distinct historical roles · {scopeLabel(params)}. No net inventory or
          provenance is inferred.
        </Text>
        {item && (
          <EntityActions game={game} kind="Item" blizzardId={item.blizzardId} />
        )}
      </header>
      {params.has("recipe") && (
        <Alert
          color="gold"
          title={`From ${inherited.data?.contextRecipe?.name ?? (inherited.loading ? "selected recipe…" : inherited.error ? "selected recipe (name could not be loaded)" : "selected recipe")}`}
        >
          This item is restricted to the recipe you came from.
          <Anchor
            ml="sm"
            component={Link}
            to={investigationLink(
              game,
              `items/${encodeURIComponent(id)}`,
              params,
              { recipe: null },
            )}
          >
            Explore across all recipes
          </Anchor>
        </Alert>
      )}
      <ScopeControls game={game} hideRoleItems />
      {["item", "input", "output", "returned"].some((key) =>
        params.has(key),
      ) && (
        <Alert color="yellow">
          Item roles are compared independently; role-specific item filters in
          this address are not applied.
          <Anchor
            component={Link}
            to={investigationLink(
              game,
              `items/${encodeURIComponent(id)}`,
              params,
              { item: null, input: null, output: null, returned: null },
            )}
          >
            {" "}
            Clear inapplicable filters
          </Anchor>
        </Alert>
      )}
      <Group>
        {["item", "input", "output", "returned"].some((key) =>
          params.has(key),
        ) ? (
          <Text size="sm" c="dimmed">
            Clear inapplicable item filters before saving.
          </Text>
        ) : (
          <SaveInvestigation game={game} />
        )}
        <Button variant="default" disabled={loading} onClick={refreshBounds}>
          Refresh investigation
        </Button>
      </Group>
      {error && <RequestError error={error} retry={refreshBounds} />}
      {loading && !data && <Loader aria-label="Loading item investigation" />}
      {data && !item && (
        <Alert color="yellow">
          This item identity is not available in the selected game.
        </Alert>
      )}
      {data && (
        <>
          {roles.map(({ role }) => (
            <SignatureNotice
              key={role}
              game={game}
              filter={roleFilter(params, id, role, now)}
              signature={
                role === "output"
                  ? data.produced.signature
                  : role === "input"
                    ? data.committed.signature
                    : (data.returned?.signature ?? "")
              }
              refresh={refreshBounds}
            />
          ))}
          <Text size="sm" c="dimmed">
            Each role is filtered independently from the same period, character
            and recipe scope. An attempt can appear in more than one role.
          </Text>
          <SimpleGrid cols={{ base: 1, md: 3 }}>
            {roles.map(({ role, title }) => {
              const analysis =
                role === "output"
                  ? data.produced
                  : role === "input"
                    ? data.committed
                    : data.returned;
              const collection =
                role === "output"
                  ? data.produced.outputs
                  : role === "input"
                    ? data.committed.inputs
                    : data.returned?.returns;
              const measure = collection?.nodes.find(
                (row) => row.id === id,
              )?.measure;
              return (
                <Card key={role} withBorder>
                  <Stack gap="xs">
                    <Title order={2}>{title}</Title>
                    <Text>
                      {exact(analysis?.attempts.attempts)} matching attempts
                    </Text>
                    {measure ? (
                      <Quantity measure={measure} />
                    ) : (
                      <Text c="dimmed">
                        {collection?.truncated
                          ? "Item not shown in first 100 ranked results"
                          : "No recorded quantity for this item in the selected role"}
                      </Text>
                    )}
                    <Button
                      component={Link}
                      to={investigationLink(
                        game,
                        "crafts",
                        roleLinkParams(params, id, role),
                      )}
                      variant="light"
                    >
                      Inspect contributing crafts
                    </Button>
                  </Stack>
                </Card>
              );
            })}
          </SimpleGrid>
          {game.project === 18 && (
            <Text size="sm" c="dimmed">
              Inputs are attributed schematic requirements, not measured
              consumption.
            </Text>
          )}
          {data.relations.itemRelations && (
            <Stack gap="lg">
              <Title order={2}>Contributing recipes & characters</Title>
              <Text size="sm" c="dimmed">
                Recorded recipe × character relationships for this item. These
                are grouped observations, not inventory provenance. Open a row
                to inspect its actual contributing crafts.
              </Text>
              <Tabs defaultValue="output" keepMounted={false}>
                <Tabs.List aria-label="Item relationships">
                  {roles.map(({ role, title }) => (
                    <Tabs.Tab value={role} key={role}>
                      {title}
                    </Tabs.Tab>
                  ))}
                </Tabs.List>
                {roles.map(({ role, title }) => {
                  const rows =
                    role === "output"
                      ? data.relations.itemRelations!.outputs
                      : role === "input"
                        ? data.relations.itemRelations!.inputs
                        : data.relations.itemRelations!.returns;
                  if (!rows) return null;
                  return (
                    <Tabs.Panel key={role} value={role}>
                      <Stack gap="xs">
                        <Title order={3}>{title}</Title>
                        {!rows.nodes.length && (
                          <Text c="dimmed">
                            No recorded relationships for this role.
                          </Text>
                        )}
                        {!!rows.nodes.length && (
                          <Table.ScrollContainer minWidth={620}>
                            <Table striped highlightOnHover withTableBorder>
                              <Table.Thead>
                                <Table.Tr>
                                  <Table.Th>Recipe</Table.Th>
                                  <Table.Th>Character</Table.Th>
                                  <Table.Th>
                                    Role quantity and coverage
                                  </Table.Th>
                                  <Table.Th>Evidence</Table.Th>
                                </Table.Tr>
                              </Table.Thead>
                              <Table.Tbody>
                                {rows.nodes.map((row, i) => (
                                  <Table.Tr
                                    key={`${row.recipeId ?? "unknown"}:${row.characterId}:${i}`}
                                  >
                                    <Table.Td>
                                      {row.recipeId ? (
                                        <LinkTo
                                          game={game}
                                          destination={`recipes/${encodeURIComponent(row.recipeId)}`}
                                          params={roleLinkParams(
                                            params,
                                            id,
                                            role,
                                          )}
                                        >
                                          {row.recipeName ?? "Unnamed recipe"}
                                        </LinkTo>
                                      ) : (
                                        "Recipe unknown"
                                      )}
                                    </Table.Td>
                                    <Table.Td>
                                      {row.characterName ?? "Unnamed character"}
                                    </Table.Td>
                                    <Table.Td>
                                      <Quantity measure={row.measure} />
                                    </Table.Td>
                                    <Table.Td>
                                      <LinkTo
                                        game={game}
                                        destination="crafts"
                                        params={withFilters(
                                          roleLinkParams(params, id, role),
                                          {
                                            character: row.characterId,
                                            ...(row.recipeId
                                              ? { recipe: row.recipeId }
                                              : {}),
                                          },
                                        )}
                                      >
                                        Inspect crafts
                                      </LinkTo>
                                    </Table.Td>
                                  </Table.Tr>
                                ))}
                              </Table.Tbody>
                            </Table>
                          </Table.ScrollContainer>
                        )}
                        <Truncated value={rows.truncated} />
                      </Stack>
                    </Tabs.Panel>
                  );
                })}
              </Tabs>
            </Stack>
          )}
        </>
      )}
    </Stack>
  );
}

function Crafts({
  game,
  params,
  filter,
  embedded = false,
  refreshBounds,
}: {
  game: ActiveGame;
  params: URLSearchParams;
  filter: CraftFilterInput;
  embedded?: boolean;
  refreshBounds: () => void;
}) {
  const [search, setSearch] = useSearchParams();
  const after = params.get("after");
  const { data, loading, error } = useQuery(InvestigationCraftsDocument, {
    variables: { context: game.canonicalId, filter, after },
    fetchPolicy: "network-only",
    errorPolicy: "all",
    notifyOnNetworkStatusChange: true,
  });
  const page = data?.contextCrafts;
  function pageTo(value: string | null) {
    const next = new URLSearchParams(search);
    if (value) next.set("after", value);
    else next.delete("after");
    setSearch(next, { replace: true });
  }
  return (
    <Stack gap="md">
      {!embedded && (
        <>
          <header>
            <Text className="eyebrow">
              {game.displayName} · contributing evidence
            </Text>
            <Title>Logbook</Title>
            <Text c="dimmed">
              {scopeLabel(params)} · newest first. An import can change pages;
              pagination is not a frozen snapshot.
            </Text>
          </header>
          <ScopeControls game={game} />
          {after ? (
            <Text size="sm" c="dimmed">
              Return to the newest page to save this scope.
            </Text>
          ) : (
            <SaveInvestigation game={game} />
          )}
        </>
      )}
      {error && <RequestError error={error} retry={refreshBounds} />}
      {loading && !page && <Loader aria-label="Loading contributing crafts" />}
      {page && (
        <>
          <Text size="sm" c="dimmed">
            {page.nodes.length} crafts on this page
            {after ? " · continued page" : ""}
          </Text>
          {!page.nodes.length && <Text>No matching recorded crafts.</Text>}
          {!!page.nodes.length && (
            <Table.ScrollContainer minWidth={650}>
              <Table striped highlightOnHover withTableBorder>
                <Table.Thead>
                  <Table.Tr>
                    <Table.Th>Recorded</Table.Th>
                    <Table.Th>Character</Table.Th>
                    <Table.Th>Recipe</Table.Th>
                    <Table.Th>Observed output</Table.Th>
                  </Table.Tr>
                </Table.Thead>
                <Table.Tbody>
                  {page.nodes.map((craft) => (
                    <Table.Tr key={craft.id}>
                      <Table.Td>
                        <LinkTo
                          game={game}
                          destination={`crafts/${encodeURIComponent(craft.id)}`}
                          params={params}
                        >
                          <time dateTime={craft.recordedAt}>
                            {new Date(craft.recordedAt).toLocaleString()}
                          </time>
                        </LinkTo>
                      </Table.Td>
                      <Table.Td>
                        {craft.character.name ?? "Unknown character"}
                      </Table.Td>
                      <Table.Td>
                        {craft.recipe?.id ? (
                          <LinkTo
                            game={game}
                            destination={`recipes/${encodeURIComponent(craft.recipe.id)}`}
                            params={params}
                          >
                            {craft.recipe.name ??
                              `Recipe ${craft.recipe.blizzardId}`}
                          </LinkTo>
                        ) : (
                          "Unknown recipe"
                        )}
                      </Table.Td>
                      <Table.Td>
                        {craft.outputs == null
                          ? "Not observed"
                          : !craft.outputs.length
                            ? "Observed empty"
                            : craft.outputs
                                .map(
                                  (output) =>
                                    `${output.item.name ?? `Item ${output.item.blizzardId}`} × ${rawQuantity(output.quantityExact)}`,
                                )
                                .join(" · ")}
                        {craft.outputsComplete === false && (
                          <Badge size="xs" ml="xs" color="yellow">
                            Incomplete
                          </Badge>
                        )}
                      </Table.Td>
                    </Table.Tr>
                  ))}
                </Table.Tbody>
              </Table>
            </Table.ScrollContainer>
          )}
          <Group>
            <Button
              variant="default"
              disabled={loading}
              onClick={refreshBounds}
            >
              Refresh page
            </Button>
            <Button
              variant="default"
              disabled={loading || !after}
              onClick={() => pageTo(null)}
            >
              Newest
            </Button>
            <Button
              disabled={
                loading ||
                !page.pageInfo.hasNextPage ||
                !page.pageInfo.endCursor
              }
              onClick={() => pageTo(page.pageInfo.endCursor)}
            >
              Next page
            </Button>
          </Group>
        </>
      )}
    </Stack>
  );
}

function Craft({
  game,
  params,
  id,
}: {
  game: ActiveGame;
  params: URLSearchParams;
  id: string;
}) {
  const { data, loading, error, refetch } = useQuery(
    InvestigationCraftDocument,
    {
      variables: { context: game.canonicalId, id },
      fetchPolicy: "network-only",
      errorPolicy: "all",
      notifyOnNetworkStatusChange: true,
    },
  );
  const craft = data?.contextCraft;
  return (
    <Stack gap="lg">
      <header>
        <Text className="eyebrow">{game.displayName} · craft evidence</Text>
        <Title>Completed craft</Title>
        {craft && (
          <Text c="dimmed">
            <time dateTime={craft.recordedAt}>
              {new Date(craft.recordedAt).toLocaleString()}
            </time>{" "}
            · {craft.character.name ?? "Unknown character"}
          </Text>
        )}
      </header>
      <Group>
        <Button
          component={Link}
          to={investigationLink(game, "crafts", params)}
          variant="light"
        >
          Back to scoped crafts
        </Button>
        <Button
          variant="default"
          disabled={loading}
          onClick={() => void refetch()}
        >
          Refresh craft
        </Button>
      </Group>
      <Text size="sm" c="dimmed">
        This lookup is by craft identity. The URL scope is preserved for
        navigation but does not filter this craft; later imports may enrich its
        observations.
      </Text>
      {error && <RequestError error={error} retry={() => void refetch()} />}
      {loading && !data && <Loader aria-label="Loading craft evidence" />}
      {data && !craft && (
        <Alert color="yellow">
          This craft was not found in the selected game.
        </Alert>
      )}
      {craft && (
        <>
          <Group>
            <Text>
              Recipe:{" "}
              {craft.recipe?.id ? (
                <LinkTo
                  game={game}
                  destination={`recipes/${encodeURIComponent(craft.recipe.id)}`}
                  params={params}
                >
                  {craft.recipe.name ?? `Recipe ${craft.recipe.blizzardId}`}
                </LinkTo>
              ) : (
                "Unknown"
              )}
            </Text>
            <Text>
              Profession: {craft.profession?.name ?? "Unknown"} ·{" "}
              {craft.professionExpansion?.name ?? "Expansion unknown"}
            </Text>
          </Group>
          <Tabs defaultValue="result" keepMounted={false}>
            <Tabs.List aria-label="Craft sections">
              <Tabs.Tab value="result">Result</Tabs.Tab>
              <Tabs.Tab value="ingredients">Ingredients</Tabs.Tab>
              {game.project === 1 && (
                <Tabs.Tab value="configuration">Configuration</Tabs.Tab>
              )}
            </Tabs.List>
            <Tabs.Panel value="result">
              <Stack gap="md">
                {game.project === 1 && (
                  <SimpleGrid cols={{ base: 1, sm: 2, lg: 3 }}>
                    {[
                      ["Concentration spent", craft.concentrationSpent],
                      ["Ingenuity refunded", craft.appliedIngenuityRefund],
                      ["Multicraft bonus", craft.multicraftBonus],
                      [
                        "Ingenuity proc",
                        craft.hasIngenuityProc == null
                          ? null
                          : craft.hasIngenuityProc
                            ? "Yes"
                            : "No",
                      ],
                      [
                        "Resourcefulness proc",
                        craft.hasResourcefulnessProc == null
                          ? null
                          : craft.hasResourcefulnessProc
                            ? "Yes"
                            : "No",
                      ],
                    ].map(([label, value]) => (
                      <Card withBorder key={label}>
                        <Text size="sm">{label}</Text>
                        <Text fw={600}>
                          {value == null ? "Unknown" : String(value)}
                        </Text>
                      </Card>
                    ))}
                  </SimpleGrid>
                )}
                <Title order={2}>Actual output</Title>
                <Text size="sm" c="dimmed">
                  Collection:{" "}
                  {craft.outputsComplete == null
                    ? "completeness unknown"
                    : craft.outputsComplete
                      ? "complete"
                      : "incomplete"}
                </Text>
                {craft.outputs == null ? (
                  <Text>Outputs not observed</Text>
                ) : craft.outputs.length === 0 ? (
                  <Text>Observed empty output collection</Text>
                ) : (
                  <Table.ScrollContainer minWidth={450}>
                    <Table striped withTableBorder>
                      <Table.Thead>
                        <Table.Tr>
                          <Table.Th>Item</Table.Th>
                          {game.project === 1 && <Table.Th>Quality</Table.Th>}
                          <Table.Th>Quantity</Table.Th>
                        </Table.Tr>
                      </Table.Thead>
                      <Table.Tbody>
                        {craft.outputs.map((row, i) => (
                          <Table.Tr key={i}>
                            <Table.Td>
                              <LinkTo
                                game={game}
                                destination={`items/${encodeURIComponent(row.item.id)}`}
                                params={params}
                              >
                                {row.item.name ?? `Item ${row.item.blizzardId}`}
                              </LinkTo>
                            </Table.Td>
                            {game.project === 1 && (
                              <Table.Td>{row.quality ?? "Unknown"}</Table.Td>
                            )}
                            <Table.Td>
                              {rawQuantity(row.quantityExact)}
                            </Table.Td>
                          </Table.Tr>
                        ))}
                      </Table.Tbody>
                    </Table>
                  </Table.ScrollContainer>
                )}
              </Stack>
            </Tabs.Panel>
            <Tabs.Panel value="ingredients">
              <Stack gap="md">
                <Title order={2}>
                  {game.project === 18
                    ? "Attributed schematic requirements"
                    : game.project === 1
                      ? "Reagents and returns"
                      : "Recorded inputs"}
                </Title>
                <Text size="sm" c="dimmed">
                  Input collection:{" "}
                  {craft.inputsComplete == null
                    ? "completeness unknown"
                    : craft.inputsComplete
                      ? "complete"
                      : "incomplete"}{" "}
                  {game.project === 18 ? (
                    ". These are attributed schematic requirements, not measured consumption."
                  ) : game.project === 1 ? (
                    <>
                      {" "}
                      · return collection:{" "}
                      {craft.resourcefulnessComplete == null
                        ? "completeness unknown"
                        : craft.resourcefulnessComplete
                          ? "complete"
                          : "incomplete"}
                      . Gross allocation and returns are distinct; an unknown is
                      not zero.
                    </>
                  ) : (
                    ". Their consumption semantics are not established for this game project."
                  )}
                </Text>
                {craft.reagents == null ? (
                  <Text>Reagents not observed</Text>
                ) : craft.reagents.length === 0 ? (
                  <Text>Observed empty reagent collection</Text>
                ) : (
                  <Table.ScrollContainer minWidth={550}>
                    <Table striped withTableBorder>
                      <Table.Thead>
                        <Table.Tr>
                          <Table.Th>Item</Table.Th>
                          <Table.Th>
                            {game.project === 18
                              ? "Attributed requirement"
                              : game.project === 1
                                ? "Gross allocated"
                                : "Recorded input"}
                          </Table.Th>
                          {game.project === 1 && <Table.Th>Returned</Table.Th>}
                        </Table.Tr>
                      </Table.Thead>
                      <Table.Tbody>
                        {craft.reagents.map((row, i) => (
                          <Table.Tr key={i}>
                            <Table.Td>
                              <LinkTo
                                game={game}
                                destination={`items/${encodeURIComponent(row.item.id)}`}
                                params={params}
                              >
                                {row.item.name ?? `Item ${row.item.blizzardId}`}
                              </LinkTo>
                              <QualityBadge quality={row.item.quality} />
                            </Table.Td>
                            <Table.Td>
                              {rawQuantity(row.allocatedQuantityExact)}
                            </Table.Td>
                            {game.project === 1 && (
                              <Table.Td>
                                {rawQuantity(row.returnedQuantityExact)}
                              </Table.Td>
                            )}
                          </Table.Tr>
                        ))}
                      </Table.Tbody>
                    </Table>
                  </Table.ScrollContainer>
                )}
              </Stack>
            </Tabs.Panel>
            {game.project === 1 && (
              <Tabs.Panel value="configuration">
                <Stack gap="md">
                  <Title order={2}>Recorded setup evidence</Title>
                  {craft.ingenuityRefund != null && (
                    <Text size="sm" c="dimmed">
                      Recorded potential Ingenuity refund:{" "}
                      {craft.ingenuityRefund}. This configured amount is not an
                      applied refund unless Ingenuity triggered.
                    </Text>
                  )}
                  {!craft.recordedConfigurations.observed && (
                    <Text c="dimmed">
                      Configuration evidence collection not observed; this is
                      not an observed empty setup.
                    </Text>
                  )}
                  {craft.recordedConfigurations.observed &&
                    !craft.recordedConfigurations.nodes.length && (
                      <Text c="dimmed">
                        Recorded empty configuration collection.
                      </Text>
                    )}
                  <Accordion variant="separated">
                    {craft.recordedConfigurations.nodes.map((row) => (
                      <Accordion.Item key={row.id} value={row.id}>
                        <Accordion.Control>
                          {configurationLabel(row.id, row.evidence)}
                        </Accordion.Control>
                        <Accordion.Panel>
                          <AnalysisEvidence
                            evidence={row.evidence}
                            available={row.evidenceAvailable}
                          />
                        </Accordion.Panel>
                      </Accordion.Item>
                    ))}
                  </Accordion>
                  <Truncated value={craft.recordedConfigurations.truncated} />
                </Stack>
              </Tabs.Panel>
            )}
          </Tabs>
        </>
      )}
    </Stack>
  );
}

export function Investigation({ game, kind }: Props) {
  const { id } = useParams();
  const [params] = useSearchParams();
  const entryParams = new URLSearchParams(params);
  entryParams.delete("characterOutcome");
  entryParams.delete("returnItem");
  for (const prefix of ["", "b"]) {
    if (
      params.get(`${prefix}period`) === "fixed" &&
      (!params.get(`${prefix}from`) || !params.get(`${prefix}to`))
    ) {
      entryParams.delete(`${prefix}from`);
      entryParams.delete(`${prefix}to`);
    }
  }
  const entry = `${game.canonicalId}:${kind}:${id ?? ""}:${entryParams.toString()}`;
  const [generation, setGeneration] = useState(0);
  const refreshBounds = () => setGeneration((current) => current + 1);
  return (
    <InvestigationEntry
      key={`${entry}:${generation}`}
      game={game}
      kind={kind}
      refreshBounds={refreshBounds}
    />
  );
}

function InvestigationEntry({
  game,
  kind,
  refreshBounds,
}: Props & { refreshBounds: () => void }) {
  const { id } = useParams();
  const [params, setSearch] = useSearchParams();
  const [now, setNow] = useState(() => new Date());
  const period = params.get("period") ?? "90";
  useEffect(() => {
    if (kind !== "activity" || !["30", "90"].includes(period)) return;
    const timer = window.setInterval(() => setNow(new Date()), 60000);
    return () => window.clearInterval(timer);
  }, [kind, period]);
  const unsupported =
    game.project !== 1
      ? ["", "b"].flatMap((prefix) =>
          retailOnlyFilters
            .map((field) => `${prefix}${field}`)
            .filter((key) => params.has(key)),
        )
      : [];
  if (unsupported.length)
    return (
      <Stack>
        <Alert
          role="alert"
          color="yellow"
          title={
            game.project === 18
              ? "Unsupported Forever filters"
              : "Unsupported Retail-only filters"
          }
        >
          {game.project === 18 ? "Forever" : "This game project"} cannot
          evaluate these Retail-only filter parameters: {unsupported.join(", ")}
          . No analysis was requested. Remove only these incompatible filters to
          continue.
          <Button
            variant="light"
            onClick={() => {
              const next = new URLSearchParams(params);
              for (const key of unsupported) next.delete(key);
              setSearch(next, { replace: true });
            }}
          >
            Clear unsupported filters
          </Button>
        </Alert>
        <ScopeControls game={game} />
        {kind === "recipe" && params.get("compare") === "1" && (
          <ScopeControls game={game} prefix="b" />
        )}
      </Stack>
    );
  let filter: CraftFilterInput;
  let second: CraftFilterInput | undefined;
  try {
    if (
      params.has("compare") &&
      (kind !== "recipe" ||
        params.get("compare") !== "1" ||
        !params.has("bperiod"))
    )
      throw new Error(
        "This comparison needs a recipe investigation and an explicit Population B period.",
      );
    if (
      params.has("characterOutcome") &&
      (!params.has("compare") ||
        !isCharacterOutcome(params.get("characterOutcome")) ||
        (game.project !== 1 && params.get("characterOutcome") !== "production"))
    )
      throw new Error(
        "This character outcome is unsupported for this investigation.",
      );
    if (
      params.has("returnItem") &&
      (params.get("characterOutcome") !== "returns" ||
        !params.get("returnItem")?.trim())
    )
      throw new Error("This investigation has an invalid returned material.");
    if (
      !params.has("compare") &&
      [
        "bperiod",
        "bfrom",
        "bto",
        "bcharacter",
        "bprofession",
        "bexpansion",
        "bgameExpansion",
        "brecipe",
        "binput",
        "babsentInput",
        "boutput",
        "breturned",
        "bitem",
        "bconfiguration",
        "bbuff",
        "babsentBuff",
        "bfinishing",
        "babsentFinishing",
      ].some((key) => params.has(key))
    )
      throw new Error("Population B filters require an active comparison.");
    if (
      kind === "recipe" &&
      params.has("recipe") &&
      params.get("recipe") !== id
    )
      throw new Error(
        "The recipe filter does not match the recipe in this address.",
      );
    filter = analysisFilter(
      params,
      "",
      kind === "recipe" ? id : undefined,
      now,
    );
    if (kind === "recipe" && params.get("compare") === "1")
      second = analysisFilter(params, "b", id, now);
    if (kind === "activity") analysisGranularity(params);
  } catch (failure) {
    return (
      <Stack>
        <Alert role="alert" color="yellow">
          {failure instanceof Error
            ? failure.message
            : "This scope is invalid."}{" "}
          Complete or change the filters to continue. No analysis was requested
          for this incomplete scope.
        </Alert>
        <ScopeControls game={game} />
        {kind === "recipe" && params.get("compare") === "1" && (
          <ScopeControls game={game} prefix="b" />
        )}
      </Stack>
    );
  }
  if ((kind === "recipe" || kind === "item" || kind === "craft") && !id)
    return (
      <Alert role="alert" color="red">
        This investigation has no entity identity.
      </Alert>
    );
  switch (kind) {
    case "activity":
      return (
        <Activity
          game={game}
          params={params}
          filter={filter}
          refreshBounds={refreshBounds}
        />
      );
    case "recipe":
      return (
        <Recipe
          game={game}
          params={params}
          filter={filter}
          id={id!}
          second={second}
          refreshBounds={refreshBounds}
        />
      );
    case "item":
      return (
        <Item
          game={game}
          params={params}
          id={id!}
          now={now}
          refreshBounds={refreshBounds}
        />
      );
    case "crafts":
      return (
        <Crafts
          game={game}
          params={params}
          filter={filter}
          refreshBounds={refreshBounds}
        />
      );
    case "craft":
      return <Craft game={game} params={params} id={id!} />;
  }
}
