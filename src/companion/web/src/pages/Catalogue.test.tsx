import { MantineProvider } from "@mantine/core";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, expect, it, vi } from "vitest";
import type { ActiveGame } from "../app/game";
import {
  IdentityCatalogueDocument,
  RecipeCatalogueDocument,
  WorkspaceFacetsDocument,
} from "../graphql/generated/graphql";
import { Catalogue } from "./Catalogue";

const query = vi.hoisted(() => vi.fn());
vi.mock("@apollo/client/react", () => ({ useQuery: query }));
vi.mock("../organization/preferences", () => ({
  useEntityPreferences: () => ({ preferences: [], loading: false }),
}));
vi.mock("../organization/EntityActions", () => ({
  EntityActions: () => null,
}));

const game: ActiveGame = {
  canonicalId: "1",
  routeAlias: "retail",
  displayName: "Retail",
  project: 1,
  progressionTrack: null,
};

beforeEach(() => {
  query.mockReset();
  query.mockImplementation((document: unknown) => {
    if (document === RecipeCatalogueDocument)
      return {
        loading: false,
        data: {
          game: {
            recipes: {
              nodes: [
                {
                  id: "r1",
                  blizzardId: 1,
                  name: "Light's Potential",
                  profession: { name: "Alchemy" },
                  expansion: { name: "Midnight" },
                  activity: {
                    craftCount: "1298",
                    lastRecordedAt: "2026-11-21T13:37:51Z",
                  },
                },
                {
                  id: "r2",
                  blizzardId: 2,
                  name: "Courtly Helm",
                  profession: null,
                  expansion: null,
                  activity: null,
                },
              ],
              pageInfo: { hasNextPage: false, endCursor: null },
            },
          },
        },
      };
    if (document === WorkspaceFacetsDocument)
      return {
        loading: false,
        data: {
          game: {
            characters: { nodes: [], pageInfo: { hasNextPage: false } },
            professions: {
              nodes: [{ id: "p1", name: "Alchemy", blizzardId: 171 }],
              pageInfo: { hasNextPage: false },
            },
          },
        },
      };
    if (document === IdentityCatalogueDocument)
      return {
        loading: false,
        data: {
          game: {
            id: "game",
            characters: {
              nodes: [
                {
                  id: "c1",
                  name: "Ogrim",
                  classFile: "WARRIOR",
                  activity: null,
                },
                {
                  id: "c2",
                  name: "Falluja",
                  classFile: "DEATHKNIGHT",
                  activity: {
                    craftCount: "61",
                    lastRecordedAt: "2026-11-21T13:26:51Z",
                  },
                },
                {
                  id: "c3",
                  name: "Kiraani",
                  classFile: "MAGE",
                  activity: {
                    craftCount: "90",
                    lastRecordedAt: "2026-11-01T10:00:00Z",
                  },
                },
              ],
              pageInfo: { hasNextPage: false },
            },
            professions: { nodes: [], pageInfo: { hasNextPage: false } },
          },
        },
      };
    return { loading: false, data: undefined };
  });
});

function renderAt(url: string) {
  render(
    <MantineProvider>
      <MemoryRouter initialEntries={[url]}>
        <Catalogue game={game} kind="recipes" />
      </MemoryRouter>
    </MantineProvider>,
  );
}

function recipeVariables() {
  const call = query.mock.calls.find(
    ([document]) => document === RecipeCatalogueDocument,
  );
  return (call?.[1] as { variables: Record<string, unknown> }).variables;
}

it("lists crafted recipes by default with their recorded activity", () => {
  renderAt("/retail/recipes?profession=p1");
  expect(recipeVariables()).toMatchObject({
    craftedOnly: true,
    profession: "p1",
  });
  expect(screen.getByText("1,298")).toBeInTheDocument();
  expect(screen.getByText("Not crafted")).toBeInTheDocument();
  expect(
    screen.getByRole("checkbox", { name: "Include recipes never crafted" }),
  ).not.toBeChecked();
});

it("includes never-crafted recipes only on request", () => {
  renderAt("/retail/recipes?uncrafted=1");
  expect(recipeVariables()).toMatchObject({
    craftedOnly: false,
    profession: null,
  });
  expect(
    screen.getByRole("checkbox", { name: "Include recipes never crafted" }),
  ).toBeChecked();
});

it("orders characters by recent activity and shows their class", () => {
  render(
    <MantineProvider>
      <MemoryRouter initialEntries={["/retail/characters"]}>
        <Catalogue game={game} kind="characters" />
      </MemoryRouter>
    </MantineProvider>,
  );
  const names = screen
    .getAllByRole("row")
    .slice(1)
    .map((row) => row.querySelector("td")?.textContent);
  expect(names).toEqual(["Falluja", "Kiraani", "Ogrim"]);
  expect(screen.getByText("Death Knight")).toBeInTheDocument();
  expect(screen.getByText("61")).toBeInTheDocument();
  expect(screen.getByText("Not crafted")).toBeInTheDocument();
});
