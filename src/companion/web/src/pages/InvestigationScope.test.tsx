import {
  ApolloClient,
  ApolloLink,
  InMemoryCache,
  Observable,
} from "@apollo/client";
import { ApolloProvider } from "@apollo/client/react";
import { MantineProvider } from "@mantine/core";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { expect, it, vi } from "vitest";
import type { ActiveGame } from "../app/game";
import { Investigation } from "./Investigation";

vi.mock("../organization", () => ({
  EntityActions: () => null,
  SaveInvestigation: () => null,
  useEntityPreferences: () => ({ preferences: [] }),
}));

const game: ActiveGame = {
  canonicalId: "1",
  routeAlias: "retail",
  displayName: "Retail",
  project: 1,
  progressionTrack: null,
};
const empty = { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } };

it("keeps both fixed-date controls editable without querying an incomplete scope", async () => {
  const requests: string[] = [];
  const client = new ApolloClient({
    cache: new InMemoryCache(),
    dataMasking: false,
    link: new ApolloLink(
      (operation) =>
        new Observable((observer) => {
          requests.push(operation.operationName ?? "");
          observer.next({
            data: {
              game: {
                id: "game",
                characters: empty,
                professions: empty,
                expansions: empty,
              },
            },
          });
          observer.complete();
        }),
    ),
  });
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter
          initialEntries={[
            "/retail/recipes/recipe-id?period=all&compare=1&bperiod=fixed",
          ]}
        >
          <Routes>
            <Route
              path="/retail/recipes/:id"
              element={<Investigation game={game} kind="recipe" />}
            />
          </Routes>
        </MemoryRouter>
      </ApolloProvider>
    </MantineProvider>,
  );
  expect(
    screen.getByText(/Choose a valid start and end date/),
  ).toBeInTheDocument();
  const from = screen.getByLabelText("bFrom");
  expect(screen.getByLabelText("bThrough")).toBeInTheDocument();
  fireEvent.change(from, { target: { value: "2026-01-01" } });
  fireEvent.blur(from);
  expect(screen.getByLabelText("bFrom")).toBe(from);
  expect(await screen.findByLabelText("bThrough")).toBeInTheDocument();
  expect(requests.every((name) => name === "WorkspaceFacets")).toBe(true);
});
