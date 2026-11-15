import { Alert, Button, Group, Text } from "@mantine/core";
import { useState } from "react";
import { RequestError } from "../components/RequestError";
import type { OrganizationGame } from "./api";
import { redactedError } from "./api";
import { useEntityPreferences } from "./preferences";

export function EntityActions({
  game,
  kind,
  blizzardId,
}: {
  game: OrganizationGame;
  kind: "Recipe" | "Item";
  blizzardId: number;
}) {
  const state = useEntityPreferences(game);
  const [pending, setPending] = useState<"pinned" | "hidden">();
  const [error, setError] = useState<Error>();
  const preference = state.preferences?.find(
    (item) => item.kind === kind && item.entityId === blizzardId,
  );
  async function change(field: "pinned" | "hidden", desired: boolean) {
    setPending(field);
    setError(undefined);
    try {
      await state.setPreference(kind, blizzardId, field, desired);
    } catch (failure) {
      setError(redactedError(failure));
    } finally {
      setPending(undefined);
    }
  }
  return (
    <div>
      {state.error && <RequestError error={state.error} retry={state.retry} />}
      {error && (
        <Alert color="red" role="alert">
          Could not save this preference. Your previous choice is unchanged.
        </Alert>
      )}
      {state.loading && <Text size="sm">Loading preferences…</Text>}
      <Group>
        <Button
          variant="light"
          disabled={
            !state.preferences ||
            !!pending ||
            !Number.isSafeInteger(blizzardId) ||
            blizzardId <= 0
          }
          onClick={() => void change("pinned", !preference?.pinned)}
        >
          {pending === "pinned"
            ? "Saving…"
            : preference?.pinned
              ? "Unpin"
              : "Pin"}
        </Button>
        <Button
          variant="light"
          disabled={
            !state.preferences ||
            !!pending ||
            !Number.isSafeInteger(blizzardId) ||
            blizzardId <= 0
          }
          onClick={() => void change("hidden", !preference?.hidden)}
        >
          {pending === "hidden"
            ? "Saving…"
            : preference?.hidden
              ? "Reveal"
              : "Hide"}
        </Button>
      </Group>
    </div>
  );
}
