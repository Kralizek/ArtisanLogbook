import { MockedProvider } from "@apollo/client/testing/react";
import { MantineProvider } from "@mantine/core";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { operationsClient } from "../api/clients";
import { LibraryEntitiesDocument } from "../graphql/generated/graphql";
import { Library } from "./Library";

vi.mock("../api/clients", () => ({
  operationsClient: {
    GET: vi.fn(),
    DELETE: vi.fn(),
    PUT: vi.fn(),
    POST: vi.fn(),
  },
}));

const game = {
  canonicalId: "18-Hardcore",
  routeAlias: "18-Hardcore",
  displayName: "Hardcore",
  project: 18,
};
const id = "550e8400-e29b-41d4-a716-446655440000";

describe("organization library", () => {
  beforeEach(() => {
    vi.mocked(operationsClient.GET).mockReset();
    vi.mocked(operationsClient.POST).mockReset();
    vi.mocked(operationsClient.PUT).mockReset();
    vi.mocked(operationsClient.GET).mockImplementation((path) => {
      if (path === "/api/v1/games/{context}/entity-preferences")
        return Promise.resolve({
          response: { status: 200 },
          data: {
            preferences: [
              {
                context: game.canonicalId,
                kind: "Recipe",
                entityId: 441,
                pinned: true,
                hidden: false,
              },
              {
                context: game.canonicalId,
                kind: "Item",
                entityId: 442,
                pinned: false,
                hidden: true,
              },
            ],
          },
        }) as never;
      return Promise.resolve({
        response: { status: 200 },
        data: {
          investigations: [
            {
              id,
              name: "Winter review",
              context: game.canonicalId,
              revision: 1,
              definitionVersion: 1,
              createdAt: "2025-01-01T00:00:00Z",
              updatedAt: "2025-01-01T00:00:00Z",
            },
          ],
        },
      }) as never;
    });
  });

  it("uses backend-resolved opaque identities for ordinary entity and saved links", async () => {
    render(
      <MantineProvider>
        <MockedProvider
          mocks={[
            {
              request: {
                query: LibraryEntitiesDocument,
                variables: {
                  context: game.canonicalId,
                  recipeIds: [441],
                  itemIds: [442],
                },
              },
              result: {
                data: {
                  game: {
                    __typename: "GameContext",
                    id: "opaque:game",
                    canonicalId: game.canonicalId,
                    recipesByBlizzardIds: [
                      {
                        id: "opaque:recipe",
                        blizzardId: 441,
                        name: "Mithril Sprocket",
                      },
                    ],
                    itemsByBlizzardIds: [
                      { id: "opaque:item", blizzardId: 442, name: null },
                    ],
                  },
                },
              },
            },
          ]}
        >
          <MemoryRouter>
            <Library game={game} />
          </MemoryRouter>
        </MockedProvider>
      </MantineProvider>,
    );
    expect(
      await screen.findByRole("link", { name: "Mithril Sprocket" }),
    ).toHaveAttribute("href", "/18-Hardcore/recipes/opaque%3Arecipe");
    expect(screen.getByRole("link", { name: "Item 442" })).toHaveAttribute(
      "href",
      "/18-Hardcore/items/opaque%3Aitem",
    );
    expect(screen.getByRole("link", { name: "Winter review" })).toHaveAttribute(
      "href",
      `/saved/${id}`,
    );
    expect(screen.getByRole("button", { name: "Reveal" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Unpin" })).toBeEnabled();
  });

  it("does not turn unresolved numeric REST preferences into invented entity links", async () => {
    render(
      <MantineProvider>
        <MockedProvider
          mocks={[
            {
              request: {
                query: LibraryEntitiesDocument,
                variables: {
                  context: game.canonicalId,
                  recipeIds: [441],
                  itemIds: [442],
                },
              },
              error: new Error("backend private details"),
            },
          ]}
        >
          <MemoryRouter>
            <Library game={game} />
          </MemoryRouter>
        </MockedProvider>
      </MantineProvider>,
    );
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Companion is unavailable",
    );
    expect(
      screen.getByText(/Recipe 441 \(link unavailable\)/),
    ).toBeInTheDocument();
    expect(
      screen.queryByText("backend private details"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("link", { name: /Recipe 441/ }),
    ).not.toBeInTheDocument();
  });

  it("renames with the fetched complete definition and its optimistic revision", async () => {
    const definition = { futureFacet: { exact: "preserve" } };
    vi.mocked(operationsClient.GET).mockImplementation((path) => {
      if (path === "/api/v1/saved-investigations/{id}")
        return Promise.resolve({
          response: { status: 200 },
          data: {
            id,
            name: "Winter review",
            context: game.canonicalId,
            revision: 1,
            definitionVersion: 2,
            definition,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-01T00:00:00Z",
          },
        }) as never;
      if (path === "/api/v1/games/{context}/entity-preferences")
        return Promise.resolve({
          response: { status: 200 },
          data: { preferences: [] },
        }) as never;
      return Promise.resolve({
        response: { status: 200 },
        data: {
          investigations: [
            {
              id,
              name: "Winter review",
              context: game.canonicalId,
              revision: 1,
              definitionVersion: 2,
              createdAt: "2025-01-01T00:00:00Z",
              updatedAt: "2025-01-01T00:00:00Z",
            },
          ],
        },
      }) as never;
    });
    vi.mocked(operationsClient.PUT).mockResolvedValue({
      response: { status: 200 },
      data: {
        id,
        name: "Renamed",
        context: game.canonicalId,
        revision: 2,
        definitionVersion: 2,
        definition,
      },
    } as never);
    render(
      <MantineProvider>
        <MockedProvider mocks={[]}>
          <MemoryRouter>
            <Library game={game} />
          </MemoryRouter>
        </MockedProvider>
      </MantineProvider>,
    );
    const name = await screen.findByRole("textbox", {
      name: "Rename Winter review",
    });
    await userEvent.clear(name);
    await userEvent.type(name, "Renamed");
    await userEvent.click(screen.getByRole("button", { name: "Rename" }));
    expect(operationsClient.PUT).toHaveBeenCalledWith(
      "/api/v1/saved-investigations/{id}",
      expect.objectContaining({
        body: {
          name: "Renamed",
          definitionVersion: 2,
          definition,
          revision: 1,
        },
      }),
    );
  });

  it("forks a stale rename rather than overwriting another tab's definition", async () => {
    const definition = {
      destination: "activity",
      scope: { period: "all" },
      query: {},
    };
    vi.mocked(operationsClient.GET).mockImplementation((path) => {
      if (path === "/api/v1/saved-investigations/{id}")
        return Promise.resolve({
          response: { status: 200 },
          data: {
            id,
            name: "Winter review",
            context: game.canonicalId,
            revision: 2,
            definitionVersion: 1,
            definition,
          },
        }) as never;
      if (path === "/api/v1/games/{context}/entity-preferences")
        return Promise.resolve({
          response: { status: 200 },
          data: { preferences: [] },
        }) as never;
      return Promise.resolve({
        response: { status: 200 },
        data: {
          investigations: [
            {
              id,
              name: "Winter review",
              context: game.canonicalId,
              revision: 1,
              definitionVersion: 1,
              createdAt: "2025-01-01T00:00:00Z",
              updatedAt: "2025-01-01T00:00:00Z",
            },
          ],
        },
      }) as never;
    });
    vi.mocked(operationsClient.POST).mockResolvedValue({
      response: { status: 201 },
      data: {
        id: "550e8400-e29b-41d4-a716-446655440001",
        revision: 1,
        context: game.canonicalId,
      },
    } as never);
    render(
      <MantineProvider>
        <MockedProvider mocks={[]}>
          <MemoryRouter>
            <Library game={game} />
          </MemoryRouter>
        </MockedProvider>
      </MantineProvider>,
    );
    const name = await screen.findByRole("textbox", {
      name: "Rename Winter review",
    });
    await userEvent.clear(name);
    await userEvent.type(name, "My copy");
    await userEvent.click(screen.getByRole("button", { name: "Rename" }));
    expect(
      await screen.findByRole("button", { name: "Save as copy" }),
    ).toBeEnabled();
    await userEvent.click(screen.getByRole("button", { name: "Save as copy" }));
    expect(operationsClient.POST).toHaveBeenCalledWith(
      "/api/v1/games/{context}/saved-investigations",
      expect.objectContaining({
        body: { name: "My copy", definitionVersion: 1, definition },
      }),
    );
    expect(operationsClient.PUT).not.toHaveBeenCalled();
  });

  it("resolves more than 100 pinned identities in bounded batches", async () => {
    vi.mocked(operationsClient.GET).mockImplementation((path) => {
      if (path === "/api/v1/games/{context}/entity-preferences")
        return Promise.resolve({
          response: { status: 200 },
          data: {
            preferences: Array.from({ length: 101 }, (_, index) => ({
              context: game.canonicalId,
              kind: "Recipe",
              entityId: index + 1,
              pinned: true,
              hidden: false,
            })),
          },
        }) as never;
      return Promise.resolve({
        response: { status: 200 },
        data: { investigations: [] },
      }) as never;
    });
    const recipe = {
      id: "last-opaque-recipe",
      blizzardId: 101,
      name: "End recipe",
    };
    render(
      <MantineProvider>
        <MockedProvider
          mocks={[
            {
              request: {
                query: LibraryEntitiesDocument,
                variables: {
                  context: game.canonicalId,
                  recipeIds: Array.from({ length: 100 }, (_, i) => i + 1),
                  itemIds: [],
                },
              },
              result: {
                data: {
                  game: {
                    __typename: "GameContext",
                    id: "opaque:game",
                    canonicalId: game.canonicalId,
                    recipesByBlizzardIds: [],
                    itemsByBlizzardIds: [],
                  },
                },
              },
            },
            {
              request: {
                query: LibraryEntitiesDocument,
                variables: {
                  context: game.canonicalId,
                  recipeIds: [101],
                  itemIds: [],
                },
              },
              result: {
                data: {
                  game: {
                    __typename: "GameContext",
                    id: "opaque:game",
                    canonicalId: game.canonicalId,
                    recipesByBlizzardIds: [recipe],
                    itemsByBlizzardIds: [],
                  },
                },
              },
            },
          ]}
        >
          <MemoryRouter>
            <Library game={game} />
          </MemoryRouter>
        </MockedProvider>
      </MantineProvider>,
    );
    expect(
      await screen.findByRole("link", { name: "End recipe" }),
    ).toHaveAttribute("href", "/18-Hardcore/recipes/last-opaque-recipe");
  });
});
