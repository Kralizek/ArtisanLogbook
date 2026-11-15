import { useApolloClient } from "@apollo/client/react";
import {
  Alert,
  Button,
  Group,
  Loader,
  Stack,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { useEffect, useState } from "react";
import { Link } from "react-router";
import { RequestError } from "../components/RequestError";
import { OperationalError } from "../api/status";
import { LibraryEntitiesDocument } from "../graphql/generated/graphql";
import {
  createSaved,
  deleteSaved,
  listSaved,
  readSaved,
  redactedError,
  updateSaved,
} from "./api";
import type { EntityPreference, OrganizationGame, SavedSummary } from "./api";
import { parseDefinition } from "./definition";
import { useEntityPreferences } from "./preferences";

function PreferenceRow({
  game,
  preference,
  entity,
  setPreference,
}: {
  game: OrganizationGame;
  preference: EntityPreference;
  entity?: { id: string; name: string | null };
  setPreference: ReturnType<typeof useEntityPreferences>["setPreference"];
}) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<Error>();
  async function change(field: "pinned" | "hidden", desired: boolean) {
    setPending(true);
    setError(undefined);
    try {
      await setPreference(preference.kind, preference.entityId, field, desired);
    } catch (failure) {
      setError(redactedError(failure));
    } finally {
      setPending(false);
    }
  }
  return (
    <Stack gap="xs">
      <Group>
        {entity ? (
          <Link
            to={`/${encodeURIComponent(game.routeAlias)}/${preference.kind === "Recipe" ? "recipes" : "items"}/${encodeURIComponent(entity.id)}`}
          >
            {entity.name ?? `${preference.kind} ${preference.entityId}`}
          </Link>
        ) : (
          <Text>
            {preference.kind} {preference.entityId} (link unavailable)
          </Text>
        )}
        <Text>
          {game.displayName}
          {preference.hidden ? " · Hidden" : ""}
          {preference.pinned ? " · Pinned" : ""}
        </Text>
        {preference.hidden && (
          <Button
            size="xs"
            variant="light"
            disabled={pending}
            onClick={() => void change("hidden", false)}
          >
            Reveal
          </Button>
        )}
        {preference.pinned && (
          <Button
            size="xs"
            variant="light"
            disabled={pending}
            onClick={() => void change("pinned", false)}
          >
            Unpin
          </Button>
        )}
      </Group>
      {error && (
        <Alert color="red" role="alert">
          Could not change this preference. Retry the action.
        </Alert>
      )}
    </Stack>
  );
}

function SavedRow({
  game,
  item,
  changed,
}: {
  game: OrganizationGame;
  item: SavedSummary;
  changed: () => void;
}) {
  const [name, setName] = useState(item.name);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<Error>();
  const [conflict, setConflict] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  async function rename() {
    if (!name.trim() || name.trim() === item.name) return;
    setPending(true);
    setError(undefined);
    try {
      const saved = await readSaved(item.id, new AbortController().signal);
      if (saved.revision !== item.revision) {
        setConflict(true);
        return;
      }
      await updateSaved(
        saved,
        name.trim(),
        saved.definition,
        saved.revision,
        new AbortController().signal,
      );
      changed();
    } catch (failure) {
      if (failure instanceof OperationalError && failure.status === 409)
        setConflict(true);
      setError(redactedError(failure));
    } finally {
      setPending(false);
    }
  }
  async function remove() {
    setPending(true);
    setError(undefined);
    try {
      await deleteSaved(item, new AbortController().signal);
      changed();
    } catch (failure) {
      if (failure instanceof OperationalError && failure.status === 409)
        setConflict(true);
      setError(redactedError(failure));
    } finally {
      setPending(false);
    }
  }
  async function fork() {
    if (!name.trim()) return;
    setPending(true);
    setError(undefined);
    try {
      const current = await readSaved(item.id, new AbortController().signal);
      if (current.context !== game.canonicalId)
        throw new Error("The investigation belongs to another context.");
      const definition = parseDefinition(
        current.definition,
        current.definitionVersion,
      );
      await createSaved(
        game,
        name.trim(),
        definition,
        new AbortController().signal,
      );
      changed();
    } catch (failure) {
      setError(redactedError(failure));
    } finally {
      setPending(false);
    }
  }
  return (
    <Stack gap="xs">
      <Group align="end">
        <Link to={`/saved/${encodeURIComponent(item.id)}`}>{item.name}</Link>
        <TextInput
          label={`Rename ${item.name}`}
          value={name}
          maxLength={120}
          onChange={(event) => setName(event.currentTarget.value)}
        />
        <Button
          size="xs"
          disabled={
            pending || !name.trim() || name.trim() === item.name || conflict
          }
          onClick={() => void rename()}
        >
          Rename
        </Button>
        {confirmDelete ? (
          <>
            <Button
              size="xs"
              color="red"
              disabled={pending || conflict}
              onClick={() => void remove()}
            >
              Confirm delete
            </Button>
            <Button
              size="xs"
              variant="default"
              onClick={() => setConfirmDelete(false)}
            >
              Cancel
            </Button>
          </>
        ) : (
          <Button
            size="xs"
            color="red"
            variant="light"
            onClick={() => setConfirmDelete(true)}
          >
            Delete
          </Button>
        )}
      </Group>
      {conflict && (
        <Alert color="orange" role="alert">
          This investigation changed elsewhere. Your typed name is preserved.
          Save a copy without overwriting the changed investigation, or refresh
          the library.
          <Button
            size="xs"
            variant="light"
            disabled={pending || !name.trim()}
            onClick={() => void fork()}
          >
            Save as copy
          </Button>
        </Alert>
      )}
      {error && <RequestError error={error} retry={changed} />}
    </Stack>
  );
}

function useLibraryEntities(
  game: OrganizationGame,
  preferences?: EntityPreference[],
) {
  const client = useApolloClient();
  const [resolved, setResolved] = useState<{
    context: string;
    signature: string;
    entities: Map<string, { id: string; name: string | null }>;
  }>();
  const [error, setError] = useState<Error>();
  const [retry, setRetry] = useState(0);
  const signature =
    preferences?.map((entry) => `${entry.kind}:${entry.entityId}`).join("|") ??
    "";
  useEffect(() => {
    if (!preferences?.length) return;
    const controller = new AbortController();
    const recipes = preferences
      .filter((entry) => entry.kind === "Recipe")
      .map((entry) => entry.entityId);
    const items = preferences
      .filter((entry) => entry.kind === "Item")
      .map((entry) => entry.entityId);
    const batches = [];
    for (
      let index = 0;
      index < Math.max(recipes.length, items.length);
      index += 100
    ) {
      batches.push({
        recipeIds: recipes.slice(index, index + 100),
        itemIds: items.slice(index, index + 100),
      });
    }
    Promise.all(
      batches.map(async (batch) => {
        const { data } = await client.query({
          query: LibraryEntitiesDocument,
          variables: { context: game.canonicalId, ...batch },
          fetchPolicy: "network-only",
          context: { fetchOptions: { signal: controller.signal } },
        });
        if (!data?.game || data.game.canonicalId !== game.canonicalId)
          throw new Error(
            "The Companion returned entities for another context.",
          );
        return data.game;
      }),
    ).then(
      (games) => {
        if (controller.signal.aborted) return;
        const found = new Map<string, { id: string; name: string | null }>();
        for (const result of games) {
          for (const recipe of result.recipesByBlizzardIds)
            found.set(`Recipe:${recipe.blizzardId}`, {
              id: recipe.id,
              name: recipe.name,
            });
          for (const item of result.itemsByBlizzardIds)
            found.set(`Item:${item.blizzardId}`, {
              id: item.id,
              name: item.name,
            });
        }
        setResolved({ context: game.canonicalId, signature, entities: found });
        setError(undefined);
      },
      (failure: unknown) => {
        if (controller.signal.aborted) return;
        setResolved(undefined);
        setError(redactedError(failure));
      },
    );
    return () => controller.abort();
    // The entity identity signature avoids refetches when only pinned/hidden changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, game.canonicalId, signature, retry]);
  return {
    entities:
      resolved?.context === game.canonicalId && resolved.signature === signature
        ? resolved.entities
        : undefined,
    error,
    retry: () => setRetry((value) => value + 1),
  };
}

export function Library({ game }: { game: OrganizationGame }) {
  const preferenceState = useEntityPreferences(game);
  const entityState = useLibraryEntities(game, preferenceState.preferences);
  const [savedResult, setSavedResult] = useState<{
    context: string;
    items: SavedSummary[];
  }>();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error>();
  const [refresh, setRefresh] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    listSaved(game, controller.signal).then(
      (entries) => {
        if (controller.signal.aborted) return;
        setSavedResult({ context: game.canonicalId, items: entries });
        setError(undefined);
        setLoading(false);
      },
      (failure: unknown) => {
        if (controller.signal.aborted) return;
        setError(redactedError(failure));
        setLoading(false);
      },
    );
    return () => controller.abort();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [game.canonicalId, refresh]);
  function reload() {
    setLoading(true);
    setError(undefined);
    setSavedResult(undefined);
    setRefresh((value) => value + 1);
  }
  const saved =
    savedResult?.context === game.canonicalId ? savedResult.items : undefined;
  return (
    <Stack>
      <Title order={1}>Library</Title>
      <Text c="dimmed">
        Pins and hidden items affect discovery only, not analytical totals.
      </Text>
      <Title order={2}>Pinned and hidden</Title>
      {preferenceState.error && (
        <RequestError
          error={preferenceState.error}
          retry={preferenceState.retry}
        />
      )}
      {entityState.error && (
        <RequestError error={entityState.error} retry={entityState.retry} />
      )}
      {preferenceState.loading && <Loader aria-label="Loading preferences" />}
      {preferenceState.preferences?.every(
        (item) => !item.pinned && !item.hidden,
      ) && <Text>No pins or hidden items.</Text>}
      {preferenceState.preferences
        ?.filter((item) => item.pinned || item.hidden)
        .map((item) => (
          <PreferenceRow
            key={`${item.kind}-${item.entityId}`}
            game={game}
            preference={item}
            entity={entityState.entities?.get(`${item.kind}:${item.entityId}`)}
            setPreference={preferenceState.setPreference}
          />
        ))}
      <Title order={2}>Saved investigations</Title>
      {(loading || (!saved && !error)) && (
        <Loader aria-label="Loading saved investigations" />
      )}
      {error && <RequestError error={error} retry={reload} />}
      {saved?.length === 0 && <Text>No saved investigations yet.</Text>}
      {saved?.map((item) => (
        <SavedRow
          key={`${item.id}-${item.revision}`}
          game={game}
          item={item}
          changed={reload}
        />
      ))}
    </Stack>
  );
}
