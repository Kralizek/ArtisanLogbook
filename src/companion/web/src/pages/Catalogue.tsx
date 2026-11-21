import { useQuery } from "@apollo/client/react";
import {
  Anchor,
  Button,
  Checkbox,
  Group,
  Loader,
  Select,
  Stack,
  Table,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import type { ReactElement } from "react";
import { Link, useSearchParams } from "react-router";
import type { ActiveGame } from "../app/game";
import { investigationLink } from "../app/scope";
import {
  IdentityCatalogueDocument,
  ItemCatalogueDocument,
  RecipeCatalogueDocument,
  WorkspaceFacetsDocument,
} from "../graphql/generated/graphql";
import { EntityActions } from "../organization/EntityActions";
import { useEntityPreferences } from "../organization/preferences";
import { RequestError } from "../components/RequestError";
import {
  ItemTooltip,
  QualityBadge,
  RecipeTooltip,
} from "../components/EntityTooltip";

type CatalogueRow = {
  id: string;
  name: string | null;
  blizzardId?: number;
  quality?: number | null;
  classFile?: string | null;
  profession?: { name: string | null } | null;
  expansion?: { name: string | null } | null;
  activity?: { craftCount: string; lastRecordedAt: string } | null;
};

const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "medium" });

export function Catalogue({
  game,
  kind,
}: {
  game: ActiveGame;
  kind: "recipes" | "items" | "characters" | "professions";
}) {
  const [params, setParams] = useSearchParams();
  const variables = {
    context: game.canonicalId,
    search: params.get("search") ?? "",
    after: params.get("after"),
  };
  const recipes = useQuery(RecipeCatalogueDocument, {
    variables: {
      ...variables,
      profession: params.get("profession"),
      // Recipes seen without any recorded craft are listed only on request.
      craftedOnly: !params.has("uncrafted"),
    },
    skip: kind !== "recipes",
    fetchPolicy: "no-cache",
  });
  const items = useQuery(ItemCatalogueDocument, {
    variables,
    skip: kind !== "items",
    fetchPolicy: "no-cache",
  });
  const facets = useQuery(WorkspaceFacetsDocument, {
    variables,
    skip: kind !== "recipes",
    fetchPolicy: "no-cache",
  });
  const identities = useQuery(IdentityCatalogueDocument, {
    variables: { context: game.canonicalId },
    skip: kind !== "characters" && kind !== "professions",
    fetchPolicy: "no-cache",
  });
  const preferences = useEntityPreferences(game);
  const result =
    kind === "recipes" ? recipes : kind === "items" ? items : identities;
  const collection =
    kind === "recipes"
      ? recipes.data?.game.recipes
      : kind === "items"
        ? items.data?.game.items
        : kind === "characters"
          ? identities.data?.game.characters
          : identities.data?.game.professions;
  const title = {
    recipes: "Recipes",
    items: "Reagents & items",
    characters: "Characters",
    professions: "Professions",
  }[kind];
  const entityKind = kind === "recipes" ? "Recipe" : "Item";
  const hidden = new Set(
    preferences.preferences
      ?.filter((p) => p.kind === entityKind && p.hidden)
      .map((p) => p.entityId),
  );
  const nodes: CatalogueRow[] | undefined =
    kind === "recipes"
      ? recipes.data?.game.recipes.nodes
      : kind === "items"
        ? items.data?.game.items.nodes
        : kind === "characters"
          ? identities.data?.game.characters.nodes
          : identities.data?.game.professions.nodes;
  const tracksActivity = kind !== "items";
  // Identity shortcuts are ordered by recency, not ranked by volume.
  const ordered =
    kind === "characters" || kind === "professions"
      ? nodes &&
        [...nodes].sort(
          (a, b) =>
            (b.activity ? Date.parse(b.activity.lastRecordedAt) : -Infinity) -
            (a.activity ? Date.parse(a.activity.lastRecordedAt) : -Infinity),
        )
      : nodes;
  const rows = ordered
    ?.filter(
      (row) =>
        ["recipes", "items"].includes(kind) ||
        `${row.name ?? ""} ${row.blizzardId ?? ""}`
          .toLowerCase()
          .includes((params.get("search") ?? "").trim().toLowerCase()),
    )
    .filter(
      (row) =>
        !(
          row.blizzardId != null &&
          ["recipes", "items"].includes(kind) &&
          hidden.has(row.blizzardId)
        ),
    );
  function change(key: string, value: string | null) {
    const next = new URLSearchParams(params);
    if (key !== "after") next.delete("after");
    if (value) next.set(key, value);
    else next.delete(key);
    setParams(next);
  }
  const scope = new URLSearchParams(params);
  scope.delete("search");
  scope.delete("uncrafted");
  return (
    <Stack gap="md">
      <header>
        <Text className="eyebrow">{game.displayName} · logbook collection</Text>
        <Title>{title}</Title>
        <Text c="dimmed">
          {kind === "items"
            ? "Materials, produced items and recorded returns. Open an item to distinguish its roles."
            : "Browse recorded identities across all history. Open an entry to investigate its activity."}
        </Text>
      </header>
      {
        <TextInput
          label={`Search ${kind === "items" ? "items" : kind}`}
          placeholder={
            {
              recipes: "Name or recipe number",
              items: "Name or item number",
              characters: "Character name",
              professions: "Name or profession number",
            }[kind]
          }
          value={params.get("search") ?? ""}
          onChange={(event) => change("search", event.currentTarget.value)}
          maw={480}
        />
      }
      {kind === "recipes" && (
        <Group align="end">
          <Select
            label="Profession"
            placeholder="All professions"
            clearable
            data={(facets.data?.game.professions.nodes ?? []).map((row) => ({
              value: row.id,
              label: row.name ?? `Profession ${row.blizzardId}`,
            }))}
            value={params.get("profession")}
            onChange={(value) => change("profession", value)}
            maw={260}
          />
          <Checkbox
            label="Include recipes never crafted"
            checked={params.has("uncrafted")}
            onChange={(event) =>
              change("uncrafted", event.currentTarget.checked ? "1" : null)
            }
            mb={8}
          />
        </Group>
      )}
      {result.error && (
        <RequestError
          error={result.error}
          retry={() => void result.refetch()}
        />
      )}
      {(result.loading ||
        (["recipes", "items"].includes(kind) && preferences.loading)) && (
        <Loader aria-label="Loading catalogue" />
      )}
      {preferences.error && ["recipes", "items"].includes(kind) && (
        <RequestError error={preferences.error} retry={preferences.retry} />
      )}
      {rows &&
        (!["recipes", "items"].includes(kind) || preferences.preferences) && (
          <Table.ScrollContainer minWidth={500}>
            <Table highlightOnHover>
              <Table.Thead>
                <Table.Tr>
                  <Table.Th>Name</Table.Th>
                  {kind === "recipes" && (
                    <Table.Th>Profession · expansion</Table.Th>
                  )}
                  {kind === "characters" && <Table.Th>Class</Table.Th>}
                  {tracksActivity && (
                    <>
                      <Table.Th>Crafts</Table.Th>
                      <Table.Th>Last crafted</Table.Th>
                    </>
                  )}
                  <Table.Th>Explore</Table.Th>
                </Table.Tr>
              </Table.Thead>
              <Table.Tbody>
                {rows.map((row) => {
                  const destination = ["recipes", "items"].includes(kind)
                    ? `${kind}/${encodeURIComponent(row.id)}`
                    : "activity";
                  const changes: Record<string, string> =
                    kind === "characters"
                      ? { character: row.id }
                      : kind === "professions"
                        ? { profession: row.id }
                        : {};
                  return (
                    <Table.Tr key={row.id}>
                      <Table.Td>
                        <EntityLinkTooltip game={game} kind={kind} id={row.id}>
                          <Anchor
                            component={Link}
                            to={investigationLink(
                              game,
                              destination,
                              scope,
                              changes,
                            )}
                          >
                            {row.name ??
                              ("blizzardId" in row
                                ? `${entityKind} ${row.blizzardId} · name unavailable`
                                : "Name unavailable")}
                          </Anchor>
                        </EntityLinkTooltip>
                        {row.quality != null && (
                          <QualityBadge quality={row.quality} />
                        )}
                        {row.blizzardId != null && kind !== "professions" && (
                          <Text size="xs" c="dimmed">
                            #{row.blizzardId}
                          </Text>
                        )}
                      </Table.Td>
                      {kind === "recipes" && (
                        <Table.Td>
                          {[
                            ...new Set(
                              [
                                row.profession?.name,
                                row.expansion?.name,
                              ].filter(Boolean),
                            ),
                          ].join(" · ")}
                        </Table.Td>
                      )}
                      {kind === "characters" && (
                        <Table.Td>{className(row.classFile)}</Table.Td>
                      )}
                      {tracksActivity && <ActivityCells row={row} />}
                      <Table.Td>
                        {row.blizzardId != null &&
                        ["recipes", "items"].includes(kind) ? (
                          <EntityActions
                            game={game}
                            kind={entityKind}
                            blizzardId={row.blizzardId}
                            compact
                            label={
                              row.name ?? `${entityKind} ${row.blizzardId}`
                            }
                          />
                        ) : (
                          <Anchor
                            component={Link}
                            to={investigationLink(
                              game,
                              "crafts",
                              scope,
                              changes,
                            )}
                          >
                            Open Logbook
                          </Anchor>
                        )}
                      </Table.Td>
                    </Table.Tr>
                  );
                })}
              </Table.Tbody>
            </Table>
          </Table.ScrollContainer>
        )}
      {rows?.length === 0 && (
        <Text c="dimmed">
          No visible entries. Try another search or restore hidden entries in
          your Library.
        </Text>
      )}
      <Group>
        <Button
          variant="default"
          disabled={!params.has("after")}
          onClick={() => change("after", null)}
        >
          First page
        </Button>
        {["recipes", "items"].includes(kind) && (
          <Button
            disabled={!collection?.pageInfo.hasNextPage || result.loading}
            onClick={() =>
              change(
                "after",
                (kind === "recipes"
                  ? recipes.data?.game.recipes.pageInfo
                  : items.data?.game.items.pageInfo
                )?.endCursor ?? null,
              )
            }
          >
            Next page
          </Button>
        )}
        <Anchor component={Link} to={`/${game.routeAlias}/library`}>
          Manage pins & hidden entries
        </Anchor>
      </Group>
      {!["recipes", "items"].includes(kind) &&
        collection?.pageInfo.hasNextPage && (
          <Text size="sm" c="dimmed">
            First 100 recorded identities shown. Use the character or profession
            selector in an investigation for a retained explicit selection.
          </Text>
        )}
    </Stack>
  );
}

function EntityLinkTooltip({
  game,
  kind,
  id,
  children,
}: {
  game: ActiveGame;
  kind: string;
  id: string;
  children: ReactElement;
}) {
  if (kind === "recipes") {
    return (
      <RecipeTooltip game={game} id={id}>
        {children}
      </RecipeTooltip>
    );
  }
  if (kind === "items") {
    return (
      <ItemTooltip game={game} id={id}>
        {children}
      </ItemTooltip>
    );
  }
  return children;
}

function ActivityCells({ row }: { row: CatalogueRow }) {
  return row.activity ? (
    <>
      <Table.Td>{BigInt(row.activity.craftCount).toLocaleString()}</Table.Td>
      <Table.Td>
        {dateFormat.format(new Date(row.activity.lastRecordedAt))}
      </Table.Td>
    </>
  ) : (
    <>
      <Table.Td>
        <Text c="dimmed" size="sm">
          Not crafted
        </Text>
      </Table.Td>
      <Table.Td />
    </>
  );
}

/** Readable class label from the client's class file token (e.g. DEATHKNIGHT). */
function className(classFile?: string | null) {
  if (!classFile) return "";
  const known: Record<string, string> = {
    DEATHKNIGHT: "Death Knight",
    DEMONHUNTER: "Demon Hunter",
  };
  return (
    known[classFile] ?? classFile.charAt(0) + classFile.slice(1).toLowerCase()
  );
}
