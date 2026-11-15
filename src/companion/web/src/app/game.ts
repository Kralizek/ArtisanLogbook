import { useEffect, useState } from "react";
import type { components } from "../api/generated";
import { operationsClient } from "../api/clients";
import { OperationalError } from "../api/status";

export type ActiveGame = components["schemas"]["GameContextMetadata"];

const preferenceKey = "artisan-logbook.last-context";

export function rememberedGame(): string | undefined {
  try {
    return localStorage.getItem(preferenceKey) ?? undefined;
  } catch {
    return undefined;
  }
}

export function rememberGame(canonicalId: string) {
  try {
    localStorage.setItem(preferenceKey, canonicalId);
  } catch {
    // This startup convenience is not durable application state.
  }
}

export async function resolveGame(context: string, signal: AbortSignal) {
  const result = await operationsClient.GET("/api/v1/games/{context}", {
    params: { path: { context } },
    signal,
  });
  if (result.error)
    throw new OperationalError(result.response.status, result.error);
  if (!result.data) throw new Error("Game metadata was not returned.");
  return result.data;
}

export function useGame(locator: string | undefined) {
  const [result, setResult] = useState<{
    locator: string;
    game?: ActiveGame;
    error?: Error;
  }>();
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    if (!locator) return;
    const controller = new AbortController();
    resolveGame(locator, controller.signal).then(
      (game) => {
        if (controller.signal.aborted) return;
        rememberGame(game.canonicalId);
        setResult({ locator, game });
      },
      (error: unknown) => {
        if (!controller.signal.aborted)
          setResult({
            locator,
            error:
              error instanceof Error ? error : new Error("Context failed."),
          });
      },
    );
    return () => controller.abort();
  }, [locator, retry]);
  return {
    game: result && result.locator === locator ? result.game : undefined,
    error: result && result.locator === locator ? result.error : undefined,
    loading: Boolean(locator && result?.locator !== locator),
    retry: () => setRetry((value) => value + 1),
  };
}
