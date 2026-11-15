import { operationsClient } from "../api/clients";
import type { components } from "../api/generated";
import { OperationalError } from "../api/status";
import type { SavedDefinition } from "./definition";

export type OrganizationGame = {
  canonicalId: string;
  routeAlias: string;
  displayName: string;
  project: number;
  progressionTrack?: string | null;
};
export type EntityPreference = components["schemas"]["EntityPreference"];
export type SavedInvestigation = components["schemas"]["SavedInvestigation"];
export type SavedSummary = components["schemas"]["SavedInvestigationSummary"];

function validRevision(value: number) {
  if (!Number.isSafeInteger(value) || value < 1)
    throw new Error("The investigation revision cannot be represented safely.");
}

function result<T>(
  data: T | undefined,
  error: components["schemas"]["Problem"] | undefined,
  response: Response,
): T {
  if (error) throw new OperationalError(response.status, error);
  if (data === undefined)
    throw new Error("The Companion returned an invalid organization response.");
  return data;
}

export async function readPreferences(
  game: OrganizationGame,
  signal: AbortSignal,
) {
  const { data, error, response } = await operationsClient.GET(
    "/api/v1/games/{context}/entity-preferences",
    { params: { path: { context: game.canonicalId } }, signal },
  );
  const preferences = result(data, error, response).preferences;
  if (preferences.some((entry) => entry.context !== game.canonicalId))
    throw new Error("The Companion returned preferences for another context.");
  return preferences;
}

export async function setPreference(
  game: OrganizationGame,
  kind: "Recipe" | "Item",
  id: number,
  field: "pinned" | "hidden",
  desired: boolean,
  signal: AbortSignal,
) {
  const options = {
    params: { path: { context: game.canonicalId, kind, id } },
    signal,
  };
  const { data, error, response } =
    field === "pinned"
      ? await operationsClient.PUT(
          "/api/v1/games/{context}/entity-preferences/{kind}/{id}/pin",
          { ...options, body: { pinned: desired } },
        )
      : await operationsClient.PUT(
          "/api/v1/games/{context}/entity-preferences/{kind}/{id}/hidden",
          { ...options, body: { hidden: desired } },
        );
  return result(data, error, response);
}

export async function listSaved(game: OrganizationGame, signal: AbortSignal) {
  const { data, error, response } = await operationsClient.GET(
    "/api/v1/games/{context}/saved-investigations",
    { params: { path: { context: game.canonicalId } }, signal },
  );
  const investigations = result(data, error, response).investigations;
  if (investigations.some((item) => item.context !== game.canonicalId))
    throw new Error(
      "The Companion returned investigations for another context.",
    );
  investigations.forEach((item) => validRevision(item.revision));
  return investigations;
}

export async function readSaved(id: string, signal: AbortSignal) {
  const { data, error, response } = await operationsClient.GET(
    "/api/v1/saved-investigations/{id}",
    { params: { path: { id } }, signal },
  );
  const saved = result(data, error, response);
  validRevision(saved.revision);
  return saved;
}

export async function resolveGame(context: string, signal: AbortSignal) {
  const { data, error, response } = await operationsClient.GET(
    "/api/v1/games/{context}",
    { params: { path: { context } }, signal },
  );
  return result(data, error, response);
}

export async function createSaved(
  game: OrganizationGame,
  name: string,
  definition: SavedDefinition,
  signal: AbortSignal,
) {
  const { data, error, response } = await operationsClient.POST(
    "/api/v1/games/{context}/saved-investigations",
    {
      params: { path: { context: game.canonicalId } },
      body: { name, definitionVersion: 1, definition },
      signal,
    },
  );
  const saved = result(data, error, response);
  validRevision(saved.revision);
  if (saved.context !== game.canonicalId)
    throw new Error(
      "The Companion returned an investigation for another context.",
    );
  return saved;
}

export async function updateSaved(
  item: SavedInvestigation,
  name: string,
  definition: Record<string, unknown>,
  revision: number,
  signal: AbortSignal,
) {
  const { data, error, response } = await operationsClient.PUT(
    "/api/v1/saved-investigations/{id}",
    {
      params: { path: { id: item.id } },
      body: {
        name,
        definitionVersion: item.definitionVersion,
        definition,
        revision,
      },
      signal,
    },
  );
  const saved = result(data, error, response);
  validRevision(saved.revision);
  if (saved.id !== item.id || saved.context !== item.context)
    throw new Error("The Companion returned an inconsistent investigation.");
  return saved;
}

export async function deleteSaved(item: SavedSummary, signal: AbortSignal) {
  const { error, response } = await operationsClient.DELETE(
    "/api/v1/saved-investigations/{id}",
    {
      params: { path: { id: item.id }, query: { revision: item.revision } },
      signal,
    },
  );
  if (error) throw new OperationalError(response.status, error);
  if (response.status !== 204)
    throw new Error("The Companion returned an invalid organization response.");
}

export function redactedError(error: unknown): Error {
  return error instanceof OperationalError
    ? error
    : new Error("The Companion is unavailable or the request failed.");
}
