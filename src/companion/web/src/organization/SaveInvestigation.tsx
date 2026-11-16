import {
  Alert,
  Button,
  Collapse,
  Group,
  Loader,
  Stack,
  TextInput,
} from "@mantine/core";
import { useEffect, useState } from "react";
import { useLocation, useNavigate } from "react-router";
import { RequestError } from "../components/RequestError";
import { OperationalError } from "../api/status";
import { createSaved, readSaved, redactedError, updateSaved } from "./api";
import type { OrganizationGame, SavedInvestigation } from "./api";
import { definitionFromLocation, definitionUrl } from "./definition";
import type { SavedDefinition } from "./definition";

export function SaveInvestigation({ game }: { game: OrganizationGame }) {
  const location = useLocation();
  const navigate = useNavigate();
  const search = new URLSearchParams(location.search);
  const id = search.get("saved");
  const revision = search.get("revision");
  const [draft, setDraft] = useState<{ origin: string | null; name: string }>({
    origin: null,
    name: "",
  });
  const name = draft.origin === id ? draft.name : "";
  const [original, setOriginal] = useState<SavedInvestigation>();
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [conflict, setConflict] = useState(false);
  const [error, setError] = useState<Error>();
  const [retry, setRetry] = useState(0);
  const [opened, setOpened] = useState(false);
  const canUpdate =
    !!id &&
    original?.id === id &&
    original.revision === Number(revision) &&
    !conflict;
  let definition: SavedDefinition | undefined;
  let invalid: Error | undefined;
  try {
    definition = definitionFromLocation(
      location.pathname,
      location.search,
      game.routeAlias,
    );
  } catch (failure) {
    invalid =
      failure instanceof Error
        ? failure
        : new Error("Unsupported investigation.");
  }
  useEffect(() => {
    if (!id || !revision) return;
    const controller = new AbortController();
    readSaved(id, controller.signal).then(
      (item) => {
        if (controller.signal.aborted) return;
        if (item.context !== game.canonicalId) {
          setError(new Error("This investigation belongs to another context."));
        } else {
          setError(undefined);
          setOriginal(item);
          setDraft((previous) =>
            previous.origin === id && previous.name
              ? previous
              : { origin: id, name: item.name },
          );
          setConflict(item.revision !== Number(revision));
        }
        setLoading(false);
      },
      (failure: unknown) => {
        if (controller.signal.aborted) return;
        setError(redactedError(failure));
        setLoading(false);
      },
    );
    return () => controller.abort();
  }, [game.canonicalId, id, revision, retry]);

  async function save(asCopy: boolean) {
    if (!definition || saving || !name.trim()) return;
    setSaving(true);
    setError(undefined);
    try {
      const controller = new AbortController();
      const saved =
        asCopy || !id
          ? await createSaved(game, name.trim(), definition, controller.signal)
          : canUpdate
            ? await updateSaved(
                original!,
                name.trim(),
                definition,
                Number(revision),
                controller.signal,
              )
            : undefined;
      if (!saved) return;
      setConflict(false);
      setOriginal(saved);
      navigate(
        definitionUrl(definition, game.routeAlias, {
          id: saved.id,
          revision: saved.revision,
        }),
        { replace: true },
      );
    } catch (failure) {
      if (failure instanceof OperationalError && failure.status === 409)
        setConflict(true);
      setError(redactedError(failure));
    } finally {
      setSaving(false);
    }
  }

  return (
    <Stack gap="xs">
      {invalid && (
        <Alert color="red" role="alert">
          {invalid.message} It was not saved.
        </Alert>
      )}
      {(loading || (!!id && !original && !error)) && (
        <Loader aria-label="Loading saved investigation" size="sm" />
      )}
      {error && (
        <RequestError
          error={error}
          retry={() => setRetry((value) => value + 1)}
        />
      )}
      {conflict && (
        <Alert color="orange" role="alert">
          This saved investigation changed elsewhere. Your edits are still in
          this tab. Save as a copy to keep them without overwriting the newer
          version.
        </Alert>
      )}
      {!invalid && (
        <>
          <Button
            variant="subtle"
            size="sm"
            onClick={() => setOpened(!opened)}
            aria-expanded={opened}
          >
            {id ? "Save / update investigation" : "Save this investigation"}
          </Button>
          <Collapse expanded={opened || !!conflict}>
            <Group align="end">
              <TextInput
                label="Investigation name"
                value={name}
                maxLength={120}
                onChange={(event) =>
                  setDraft({ origin: id, name: event.currentTarget.value })
                }
                placeholder="Name this investigation"
              />
              <Button
                disabled={
                  !name.trim() || loading || saving || (!!id && !canUpdate)
                }
                onClick={() => void save(false)}
              >
                {id ? "Save changes" : "Save investigation"}
              </Button>
              {id && (
                <Button
                  variant="light"
                  disabled={!name.trim() || saving || loading}
                  onClick={() => void save(true)}
                >
                  Save as copy
                </Button>
              )}
            </Group>
          </Collapse>
        </>
      )}
    </Stack>
  );
}
