import { Alert, Loader, Stack, Title } from "@mantine/core";
import { useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { RequestError } from "../components/RequestError";
import { readSaved, redactedError, resolveGame } from "./api";
import { definitionUrl, parseDefinition } from "./definition";

export function SavedInvestigationEntry() {
  const { id } = useParams();
  const navigate = useNavigate();
  const [error, setError] = useState<Error>();
  const [invalid, setInvalid] = useState<string>();
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    if (!id) return;
    const controller = new AbortController();
    async function open() {
      try {
        const saved = await readSaved(id!, controller.signal);
        let definition;
        try {
          definition = parseDefinition(
            saved.definition,
            saved.definitionVersion,
          );
        } catch {
          setInvalid("This saved investigation has an unsupported definition.");
          return;
        }
        const game = await resolveGame(saved.context, controller.signal);
        if (game.canonicalId !== saved.context)
          throw new Error(
            "The saved investigation context could not be resolved.",
          );
        if (!controller.signal.aborted)
          navigate(
            definitionUrl(definition, game.routeAlias, {
              id: saved.id,
              revision: saved.revision,
            }),
            { replace: true },
          );
      } catch (failure) {
        if (controller.signal.aborted) return;
        setError(redactedError(failure));
      }
    }
    void open();
    return () => controller.abort();
  }, [id, navigate, retry]);
  return (
    <Stack>
      <Title order={1}>Opening saved investigation</Title>
      {!id || invalid ? (
        <Alert role="alert" color="red">
          {invalid ?? "This saved investigation has an invalid address."} This
          definition was not executed.
        </Alert>
      ) : error ? (
        <RequestError
          error={error}
          retry={() => setRetry((value) => value + 1)}
        />
      ) : (
        <Loader aria-label="Opening saved investigation" />
      )}
    </Stack>
  );
}
