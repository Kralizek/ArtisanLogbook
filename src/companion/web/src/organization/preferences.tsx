import { createContext, useContext, useEffect, useState } from "react";
import type { ReactNode } from "react";
import { readPreferences, redactedError, setPreference } from "./api";
import type { EntityPreference, OrganizationGame } from "./api";

type PreferenceState = {
  preferences?: EntityPreference[];
  loading: boolean;
  error?: Error;
  retry: () => void;
  setPreference: (
    kind: "Recipe" | "Item",
    id: number,
    field: "pinned" | "hidden",
    desired: boolean,
  ) => Promise<void>;
};

const PreferenceContext = createContext<{
  context: string;
  state: PreferenceState;
} | null>(null);

export function EntityPreferencesProvider({
  game,
  children,
}: {
  game: OrganizationGame;
  children: ReactNode;
}) {
  const state = usePreferencesForGameOrIdle(game, false);
  return (
    <PreferenceContext.Provider value={{ context: game.canonicalId, state }}>
      {children}
    </PreferenceContext.Provider>
  );
}

// eslint-disable-next-line react-refresh/only-export-components
export function useEntityPreferences(game: OrganizationGame): PreferenceState {
  const shared = useContext(PreferenceContext);
  // Hooks cannot be conditional: the local state is idle while a matching provider owns the state.
  const local = usePreferencesForGameOrIdle(
    game,
    !!shared && shared.context === game.canonicalId,
  );
  return shared?.context === game.canonicalId ? shared.state : local;
}

function usePreferencesForGameOrIdle(
  game: OrganizationGame,
  idle: boolean,
): PreferenceState {
  const [preferences, setPreferences] = useState<EntityPreference[]>();
  const [loadedContext, setLoadedContext] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error>();
  const [refresh, setRefresh] = useState(0);
  useEffect(() => {
    if (idle) return;
    const controller = new AbortController();
    readPreferences(game, controller.signal).then(
      (entries) => {
        if (!controller.signal.aborted) {
          setLoadedContext(game.canonicalId);
          setPreferences(entries);
          setError(undefined);
          setLoading(false);
        }
      },
      (failure: unknown) => {
        if (!controller.signal.aborted) {
          setLoadedContext(game.canonicalId);
          setPreferences(undefined);
          setError(redactedError(failure));
          setLoading(false);
        }
      },
    );
    return () => controller.abort();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [game.canonicalId, idle, refresh]);
  return {
    preferences:
      idle || loadedContext !== game.canonicalId ? undefined : preferences,
    loading: loadedContext !== game.canonicalId || loading,
    error: loadedContext === game.canonicalId ? error : undefined,
    retry() {
      setLoading(true);
      setPreferences(undefined);
      setError(undefined);
      setRefresh((value) => value + 1);
    },
    async setPreference(kind, id, field, desired) {
      const updated = await setPreference(
        game,
        kind,
        id,
        field,
        desired,
        new AbortController().signal,
      );
      if (
        updated.context !== game.canonicalId ||
        updated.kind !== kind ||
        updated.entityId !== id
      )
        throw new Error("The Companion returned an inconsistent preference.");
      setPreferences((current) => {
        if (!current || loadedContext !== game.canonicalId) return current;
        const index = current.findIndex(
          (entry) => entry.kind === kind && entry.entityId === id,
        );
        const prior =
          index < 0
            ? {
                context: game.canonicalId,
                kind,
                entityId: id,
                pinned: false,
                hidden: false,
              }
            : current[index];
        const entry = { ...prior, [field]: updated[field] };
        return index < 0
          ? [...current, entry]
          : current.map((value, i) => (i === index ? entry : value));
      });
    },
  };
}
