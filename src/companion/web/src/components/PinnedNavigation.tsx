import { useQuery } from "@apollo/client/react";
import { NavLink, Text } from "@mantine/core";
import { Link } from "react-router";
import type { ActiveGame } from "../app/game";
import { LibraryEntitiesDocument } from "../graphql/generated/graphql";
import { useEntityPreferences } from "../organization/preferences";

export function PinnedNavigation({
  game,
  close,
}: {
  game: ActiveGame;
  close: () => void;
}) {
  const state = useEntityPreferences(game);
  const pins =
    state.preferences?.filter(
      (p) => p.pinned && !p.hidden && p.kind === "Recipe",
    ) ?? [];
  const ids = pins.slice(0, 100).map((p) => p.entityId);
  const { data, error } = useQuery(LibraryEntitiesDocument, {
    variables: { context: game.canonicalId, recipeIds: ids, itemIds: [] },
    skip: !ids.length,
    fetchPolicy: "no-cache",
  });
  return (
    <>
      <Text className="nav-section">Pinned recipes</Text>
      {!pins.length && (
        <Text size="xs" px="sm" c="dimmed">
          Pin recipes to keep them close.
        </Text>
      )}
      {(state.error || error) && (
        <Text size="xs" px="sm">
          Pins could not be loaded. Open Library to retry.
        </Text>
      )}
      {data?.game.recipesByBlizzardIds.map((recipe) => (
        <NavLink
          key={recipe.id}
          component={Link}
          to={`/${game.routeAlias}/recipes/${encodeURIComponent(recipe.id)}?period=90`}
          label={recipe.name ?? `Recipe ${recipe.blizzardId}`}
          title={recipe.name ?? `Recipe ${recipe.blizzardId}`}
          onClick={close}
        />
      ))}
      {pins.length > 100 && (
        <NavLink
          component={Link}
          to={`/${game.routeAlias}/library`}
          label="View all pinned recipes"
          onClick={close}
        />
      )}
    </>
  );
}
