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
  compact = false,
  label,
}: {
  game: OrganizationGame;
  kind: "Recipe" | "Item";
  blizzardId: number;
  /** Quiet inline controls for dense lists such as catalogue rows. */
  compact?: boolean;
  /** Entity name for accessible control names when many rows repeat them. */
  label?: string;
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
      {state.loading && !compact && <Text size="sm">Loading preferences…</Text>}
      <Group gap={compact ? 4 : undefined} wrap="nowrap">
        <Button
          variant={compact ? "subtle" : "light"}
          size={compact ? "compact-xs" : undefined}
          aria-label={
            label && pending !== "pinned"
              ? `${preference?.pinned ? "Unpin" : "Pin"} ${label}`
              : undefined
          }
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
          variant={compact ? "subtle" : "light"}
          size={compact ? "compact-xs" : undefined}
          aria-label={
            label && pending !== "hidden"
              ? `${preference?.hidden ? "Reveal" : "Hide"} ${label}`
              : undefined
          }
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
