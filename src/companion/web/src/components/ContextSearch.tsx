import { useState } from "react";
import { useDebouncedValue } from "@mantine/hooks";
import { useQuery } from "@apollo/client/react";
import {
  Alert,
  Anchor,
  Badge,
  Box,
  Loader,
  Stack,
  Text,
  TextInput,
} from "@mantine/core";
import { Link } from "react-router";
import { WorkspaceSearchDocument } from "../graphql/generated/graphql";
import type { ActiveGame } from "../app/game";

export function ContextSearch({ game }: { game: ActiveGame }) {
  const [text, setText] = useState("");
  const [search] = useDebouncedValue(text.trim(), 250);
  const { data, error, loading } = useQuery(WorkspaceSearchDocument, {
    variables: { context: game.canonicalId, search },
    skip: !search,
    fetchPolicy: "no-cache",
  });
  return (
    <Box className="shell-search">
      <TextInput
        aria-label={`Search recipes and items in ${game.displayName}`}
        placeholder="Find a recipe or material…"
        value={text}
        onChange={(event) => setText(event.currentTarget.value)}
        rightSection={loading ? <Loader size="xs" /> : undefined}
      />
      {text.trim() && (
        <Box
          className="search-results"
          role="region"
          aria-label="Search results"
        >
          <Stack gap="xs">
            <Text size="xs" c="dimmed">
              All recorded history in {game.displayName} · opens a new
              investigation
            </Text>
            {error && (
              <Alert color="red">
                Search is unavailable. Try again after checking the Companion.
              </Alert>
            )}
            {!loading &&
              !error &&
              data &&
              data.game.recipes.nodes.length + data.game.items.nodes.length ===
                0 && (
                <Text size="sm">No matching recorded recipes or items.</Text>
              )}
            {data?.game.recipes.nodes.map((recipe) => (
              <Anchor
                component={Link}
                key={`recipe-${recipe.id}`}
                to={`/${game.routeAlias}/recipes/${encodeURIComponent(recipe.id)}?period=all`}
                onClick={() => setText("")}
              >
                <Badge size="xs" variant="light" mr="xs">
                  Recipe
                </Badge>
                {recipe.name ?? `Recipe ${recipe.blizzardId}`}
              </Anchor>
            ))}
            {data?.game.items.nodes.map((item) => (
              <Anchor
                component={Link}
                key={`item-${item.id}`}
                to={`/${game.routeAlias}/items/${encodeURIComponent(item.id)}?period=all`}
                onClick={() => setText("")}
              >
                <Badge size="xs" variant="light" color="blue" mr="xs">
                  Item
                </Badge>
                {item.name ?? `Item ${item.blizzardId} · name unavailable`}
                {item.name && (
                  <Text component="span" size="xs" c="dimmed">
                    {" "}
                    · #{item.blizzardId}
                  </Text>
                )}
              </Anchor>
            ))}
            {(data?.game.recipes.pageInfo.hasNextPage ||
              data?.game.items.pageInfo.hasNextPage) && (
              <Text size="xs" c="dimmed">
                Showing the first 20 of each kind. Refine your search to find
                more.
              </Text>
            )}
          </Stack>
        </Box>
      )}
    </Box>
  );
}
