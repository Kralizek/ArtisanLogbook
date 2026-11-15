import { MantineProvider } from "@mantine/core";
import {
  ApolloClient,
  ApolloLink,
  InMemoryCache,
  Observable,
} from "@apollo/client";
import { ApolloProvider } from "@apollo/client/react";
import { MockLink } from "@apollo/client/testing";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import {
  MemoryRouter,
  Route,
  Routes,
  useLocation,
  useSearchParams,
} from "react-router";
import { expect, it, vi } from "vitest";
import { createHistoryCache } from "../api/clients";
import type { ActiveGame } from "../app/game";
import {
  ActivityInvestigationDocument,
  InvestigationCraftDocument,
  InvestigationCraftsDocument,
  InvestigationSignatureDocument,
  ItemInvestigationDocument,
  LibraryEntitiesDocument,
  RecipeConfigurationsDocument,
  RecipeInvestigationDocument,
} from "../graphql/generated/graphql";
import { Investigation } from "./Investigation";

const organization = vi.hoisted(() => ({
  preferences: [] as {
    hidden: boolean;
    kind: "Recipe" | "Item";
    entityId: number;
  }[],
}));
vi.mock("../organization", () => ({
  EntityActions: () => null,
  SaveInvestigation: () => null,
  useEntityPreferences: () => ({
    preferences: organization.preferences,
    error: undefined,
  }),
}));
vi.mock("../components/ScopeControls", () => ({
  ItemFilter: ({ label }: { label: string }) => <div>{label}</div>,
  ScopeControls: ({ prefix }: { prefix?: string }) => (
    <div>{prefix ? "Population B filters" : "Population A filters"}</div>
  ),
}));

const game: ActiveGame = {
  canonicalId: "1",
  routeAlias: "retail",
  displayName: "Retail",
  project: 1,
  progressionTrack: null,
};
const measure = (attempts: string, quantity: string | null) => ({
  __typename: "AnalysisMeasure",
  attempts,
  measuredAttempts: attempts,
  incompleteAttempts: "0",
  quantity,
});
const outcome = (attempts: string, positive: string) => ({
  __typename: "AnalysisOutcome",
  observedAttempts: attempts,
  positiveAttempts: positive,
  unknownAttempts: "0",
  total: positive,
});
function analysis(attempts: string, signature: string) {
  return {
    signature,
    configurationCoverage: {
      recordedAttempts: "0",
      emptyAttempts: "0",
      unknownAttempts: attempts,
    },
    inputMeasureLabel: "Gross allocated inputs",
    supportsReturns: true,
    attempts: measure(attempts, null),
    timeline: {
      nodes: [{ start: "2026-11-07", measure: { attempts } }],
      truncated: false,
    },
    recipes: {
      nodes: [
        {
          __typename: "RecipeAnalysisGraph",
          id: "recipe-opaque",
          name: "Test recipe",
          outputs: measure(attempts, attempts),
          ingenuity: outcome(attempts, "1"),
          resourcefulness: outcome(attempts, "0"),
          multicraft: outcome(attempts, "0"),
          concentration: outcome(attempts, "0"),
          refund: outcome(attempts, "0"),
        },
      ],
      truncated: false,
    },
    outputs: {
      __typename: "AnalysisContributions",
      nodes: [
        {
          id: "item-opaque",
          name: "Test item",
          measure: measure(attempts, "1"),
        },
      ],
      truncated: false,
    },
    inputs: {
      __typename: "AnalysisContributions",
      nodes: [],
      truncated: false,
    },
    returns: {
      __typename: "AnalysisContributions",
      nodes: [],
      truncated: false,
    },
    qualities: { nodes: [], truncated: false },
    characters: { nodes: [], truncated: false },
    configurations: { nodes: [], truncated: false },
  };
}
function configurationAnalysis(signature: string) {
  return {
    signature,
    supportsReturns: true,
    configurationCoverage: {
      recordedAttempts: "0",
      emptyAttempts: "0",
      unknownAttempts: "0",
    },
    configurations: { nodes: [], truncated: false },
  };
}
const recipe = {
  id: "recipe-opaque",
  name: "Test recipe",
  blizzardId: 100,
  profession: null,
  expansion: null,
};
const a = {
  context: game.canonicalId,
  id: recipe.id,
  filter: { recipeId: recipe.id },
};
const b = {
  context: game.canonicalId,
  id: recipe.id,
  filter: { recipeId: recipe.id, characterId: "char-b" },
};
const mocks = [
  {
    request: {
      query: RecipeConfigurationsDocument,
      variables: { context: game.canonicalId, filter: a.filter },
    },
    result: { data: { analysis: configurationAnalysis("sig-a") } },
  },
  {
    request: {
      query: RecipeConfigurationsDocument,
      variables: { context: game.canonicalId, filter: b.filter },
    },
    result: { data: { analysis: configurationAnalysis("sig-b") } },
  },
  {
    request: { query: RecipeInvestigationDocument, variables: a },
    result: { data: { recipe, analysis: analysis("12", "sig-a") } },
  },
  {
    request: { query: RecipeInvestigationDocument, variables: b },
    result: { data: { recipe, analysis: analysis("3", "sig-b") } },
  },
  {
    request: {
      query: InvestigationSignatureDocument,
      variables: { context: game.canonicalId, filter: a.filter },
    },
    result: { data: { analysisSignature: "sig-a-new" } },
  },
  {
    request: {
      query: InvestigationSignatureDocument,
      variables: { context: game.canonicalId, filter: b.filter },
    },
    result: { data: { analysisSignature: "sig-b" } },
  },
  {
    request: {
      query: InvestigationCraftsDocument,
      variables: { context: game.canonicalId, filter: a.filter, after: null },
    },
    result: {
      data: {
        contextCrafts: {
          nodes: [],
          pageInfo: { hasNextPage: false, endCursor: null },
        },
      },
    },
  },
];

it("freezes both relative recipe populations through unrelated renders and advances them only on explicit refresh", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  try {
    vi.setSystemTime(new Date("2026-11-15T12:00:00Z"));
    organization.preferences = [];
    const calls: {
      name: string | undefined;
      variables: Record<string, unknown>;
    }[] = [];
    const client = new ApolloClient({
      cache: new InMemoryCache(),
      dataMasking: false,
      link: new ApolloLink(
        (operation) =>
          new Observable((observer) => {
            calls.push({
              name: operation.operationName,
              variables: operation.variables,
            });
            const filter = operation.variables.filter as
              { from: string; characterId?: string } | undefined;
            const refreshed = filter?.from.startsWith("2026-10-17") ?? false;
            const body =
              operation.operationName === "RecipeInvestigation"
                ? {
                    recipe,
                    analysis: analysis(
                      filter?.characterId
                        ? refreshed
                          ? "4"
                          : "3"
                        : refreshed
                          ? "30"
                          : "12",
                      refreshed ? "new" : "old",
                    ),
                  }
                : operation.operationName === "RecipeConfigurations"
                  ? {
                      analysis: configurationAnalysis(
                        refreshed ? "new" : "old",
                      ),
                    }
                  : operation.operationName === "InvestigationSignature"
                    ? { analysisSignature: refreshed ? "new" : "old" }
                    : {
                        contextCrafts: {
                          nodes: [],
                          pageInfo: { hasNextPage: false, endCursor: null },
                        },
                      };
            observer.next({ data: body });
            observer.complete();
          }),
      ),
    });
    function Journey() {
      const [, rerender] = useState(0);
      const [search, setSearch] = useSearchParams();
      return (
        <>
          <div data-testid="search">{search.toString()}</div>
          <button onClick={() => rerender((value) => value + 1)}>
            Unrelated render
          </button>
          <button
            onClick={() => {
              const next = new URLSearchParams(search);
              next.set("characterOutcome", "production");
              setSearch(next);
            }}
          >
            Change displayed outcome
          </button>
          <Routes>
            <Route
              path="/retail/recipes/:id"
              element={<Investigation game={game} kind="recipe" />}
            />
          </Routes>
        </>
      );
    }
    render(
      <MantineProvider>
        <ApolloProvider client={client}>
          <MemoryRouter
            initialEntries={[
              "/retail/recipes/recipe-opaque?period=30&buff=123&compare=1&bperiod=90&characterOutcome=resourcefulness",
            ]}
          >
            <Journey />
          </MemoryRouter>
        </ApolloProvider>
      </MantineProvider>,
    );
    await screen.findByText("Population B characters");
    expect(
      screen.getByRole("combobox", { name: "Outcome to compare" }),
    ).toHaveValue("Resourcefulness proc rate");
    const recipeCalls = () =>
      calls.filter((call) => call.name === "RecipeInvestigation");
    expect(recipeCalls()).toHaveLength(2);
    const original = recipeCalls().map(
      (call) => (call.variables.filter as { from: string }).from,
    );
    vi.setSystemTime(new Date("2026-11-16T12:00:00Z"));
    await userEvent.click(
      screen.getByRole("button", { name: "Unrelated render" }),
    );
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(recipeCalls()).toHaveLength(2);
    expect(
      recipeCalls().map(
        (call) => (call.variables.filter as { from: string }).from,
      ),
    ).toEqual(original);
    await userEvent.click(
      screen.getByRole("button", { name: "Change displayed outcome" }),
    );
    expect(
      screen.getByRole("combobox", { name: "Outcome to compare" }),
    ).toHaveValue("Actual output per craft");
    expect(recipeCalls()).toHaveLength(2);
    await userEvent.click(
      screen.getByRole("button", { name: "Refresh investigation" }),
    );
    await waitFor(() => expect(recipeCalls()).toHaveLength(4));
    expect(
      screen.getByRole("combobox", { name: "Outcome to compare" }),
    ).toHaveValue("Actual output per craft");
    expect(
      recipeCalls()
        .slice(2)
        .map((call) => (call.variables.filter as { from: string }).from),
    ).not.toEqual(original);
    expect(recipeCalls()[2].variables.filter).toMatchObject({
      recipeId: "recipe-opaque",
    });
    expect(recipeCalls()[3].variables.filter).toMatchObject({
      recipeId: "recipe-opaque",
    });
    await userEvent.click(
      screen.getByRole("button", { name: "Remove comparison" }),
    );
    const remaining = new URLSearchParams(
      screen.getByTestId("search").textContent ?? "",
    );
    expect(remaining.get("buff")).toBe("123");
    expect(remaining.has("bperiod")).toBe(false);
    expect(remaining.has("characterOutcome")).toBe(false);
  } finally {
    vi.useRealTimers();
  }
});

it("compares independently filtered recorded populations and retains detail when relevant evidence changes", async () => {
  organization.preferences = [];
  const client = new ApolloClient({
    cache: createHistoryCache(),
    link: new MockLink(mocks),
    dataMasking: false,
  });
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter
          initialEntries={[
            "/retail/recipes/recipe-opaque?period=all&compare=1&bperiod=all&bcharacter=char-b",
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
  expect(await screen.findByText("Population B filters")).toBeInTheDocument();
  const outcomeTable = (await screen.findByText("Observed outcome")).closest(
    "table",
  );
  if (!outcomeTable) throw new Error("Missing outcome table");
  expect(within(outcomeTable).getByText("Population A")).toBeInTheDocument();
  expect(within(outcomeTable).getByText("Population B")).toBeInTheDocument();
  expect(
    await screen.findByText("Relevant history changed"),
  ).toBeInTheDocument();
  expect(screen.getAllByText("12").length).toBeGreaterThan(0);
  expect(screen.getAllByText("3").length).toBeGreaterThan(0);
  const attempts = screen.getByRole("row", { name: /Completed attempts/ });
  expect(
    within(attempts)
      .getAllByRole("cell")
      .map((cell) => cell.textContent),
  ).toEqual(["Completed attempts", "12", "3"]);
  expect(screen.getByText("Recorded setup differences")).toBeInTheDocument();
  expect(screen.getByText("Population B characters")).toBeInTheDocument();
  expect(screen.getByText("Recipe activity over time")).toBeInTheDocument();
  const firstBar = screen.getByRole("link", {
    name: "2026-11-07 – 2026-11-07: 12 completed crafts",
  });
  const secondBar = screen.getByRole("link", {
    name: "2026-11-07 – 2026-11-07: 3 completed crafts",
  });
  expect(firstBar.getAttribute("href")).toContain("recipe=recipe-opaque");
  expect(firstBar.getAttribute("href")).toContain("period=fixed");
  expect(secondBar.getAttribute("href")).toContain("character=char-b");
  expect(secondBar.getAttribute("href")).not.toContain("bcharacter=");
  expect(secondBar.getAttribute("href")).not.toContain("compare=");
  const itemLink = screen.getByRole("link", { name: "Test item" });
  expect(itemLink).toHaveAttribute(
    "href",
    expect.stringContaining("recipe=recipe-opaque"),
  );
  expect(itemLink.getAttribute("href")).not.toContain("compare=");
});

it.each([
  ["absentFinishing=item-a&bfinishing=item-a", true],
  ["absentFinishing=item-a&bfinishing=item-b", false],
  ["absentFinishing=item-a&bfinishing=item-a&finishing=item-b", false],
  ["absentFinishing=item-a&bfinishing=item-a&babsentFinishing=item-b", false],
  ["absentInput=item-a&binput=item-a", true],
  ["absentInput=item-a&binput=item-b", false],
  ["absentInput=item-a&binput=item-a&babsentInput=item-b", false],
  ["absentInput=item-a&binput=item-a&finishing=item-b", false],
])(
  "only offers per-unit comparison for matching absence and presence: %s",
  async (filters, expected) => {
    const client = new ApolloClient({
      cache: createHistoryCache(),
      dataMasking: false,
      link: new ApolloLink(
        (operation) =>
          new Observable((observer) => {
            const data =
              operation.operationName === "RecipeInvestigation"
                ? { recipe, analysis: analysis("2", "sig") }
                : operation.operationName === "RecipeConfigurations"
                  ? { analysis: configurationAnalysis("sig") }
                  : operation.operationName === "InvestigationSignature"
                    ? { analysisSignature: "sig" }
                    : {
                        contextCrafts: {
                          nodes: [],
                          pageInfo: { hasNextPage: false, endCursor: null },
                        },
                      };
            observer.next({ data });
            observer.complete();
          }),
      ),
    });
    render(
      <MantineProvider>
        <ApolloProvider client={client}>
          <MemoryRouter
            initialEntries={[
              `/retail/recipes/recipe-opaque?period=all&compare=1&bperiod=all&${filters}`,
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
    await screen.findByText("Population B characters");
    expect(!!screen.queryByText("Difference per allocated unit")).toBe(
      expected,
    );
  },
);

it("keeps returned-material evidence scoped to the comparison and rejects stale snapshots", async () => {
  const requests: { item: string; filter: Record<string, unknown> }[] = [];
  const character = {
    id: "char-match",
    name: "Artisan",
    measure: measure("2", null),
    resourceAllocation: null,
    metrics: {
      production: measure("2", "2"),
      ingenuity: outcome("2", "0"),
      resourcefulness: outcome("2", "0"),
      multicraft: outcome("2", "0"),
    },
  };
  const client = new ApolloClient({
    cache: createHistoryCache(),
    dataMasking: false,
    link: new ApolloLink(
      (operation) =>
        new Observable((observer) => {
          let data;
          if (operation.operationName === "RecipeInvestigation") {
            const population = {
              ...analysis("2", "sig"),
              characters: { nodes: [character], truncated: false },
            };
            data = { recipe, analysis: population };
          } else if (operation.operationName === "CharacterReturns") {
            const filter = operation.variables.filter as Record<
              string,
              unknown
            >;
            requests.push({ item: operation.variables.item as string, filter });
            data = {
              analysis: {
                signature: filter.characterId === "char-b" ? "changed" : "sig",
                characters: {
                  nodes: [
                    { id: "char-match", returnedItem: measure("2", "1") },
                  ],
                  truncated: false,
                },
              },
            };
          } else if (operation.operationName === "RecipeConfigurations")
            data = { analysis: configurationAnalysis("sig") };
          else if (operation.operationName === "InvestigationSignature")
            data = { analysisSignature: "sig" };
          else
            data = {
              contextCrafts: {
                nodes: [],
                pageInfo: { hasNextPage: false, endCursor: null },
              },
            };
          observer.next({ data });
          observer.complete();
        }),
    ),
  });
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter
          initialEntries={[
            "/retail/recipes/recipe-opaque?period=all&character=char-a&compare=1&bperiod=all&bcharacter=char-b&characterOutcome=returns&returnItem=item-a",
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
    await screen.findByText("Returned material evidence changed"),
  ).toBeInTheDocument();
  expect(requests).toHaveLength(2);
  expect(requests.map((request) => request.item)).toEqual(["item-a", "item-a"]);
  expect(
    requests.every((request) => !("returnedItemId" in request.filter)),
  ).toBe(true);
  expect(
    screen.getByText("Insufficient observed evidence"),
  ).toBeInTheDocument();
});

it("reports failed freshness checks and retries without losing displayed evidence", async () => {
  organization.preferences = [];
  let checks = 0;
  const client = new ApolloClient({
    cache: new InMemoryCache(),
    dataMasking: false,
    link: new ApolloLink(
      (operation) =>
        new Observable((observer) => {
          if (operation.operationName === "RecipeInvestigation")
            observer.next({
              data: { recipe, analysis: analysis("12", "sig-a") },
            });
          else if (operation.operationName === "RecipeConfigurations")
            observer.next({
              data: { analysis: configurationAnalysis("sig-a") },
            });
          else if (operation.operationName === "InvestigationSignature") {
            if (++checks === 1) {
              observer.error(new Error("Freshness query unavailable"));
              return;
            }
            observer.next({ data: { analysisSignature: "sig-a" } });
          }
          observer.complete();
        }),
    ),
  });
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter
          initialEntries={["/retail/recipes/recipe-opaque?period=all"]}
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
    await screen.findByText("Cannot check for new evidence"),
  ).toBeInTheDocument();
  expect(screen.getAllByText("12").length).toBeGreaterThan(0);
  expect(
    screen.getByText(/its freshness could not be checked/),
  ).toBeInTheDocument();
  await userEvent.click(
    screen.getByRole("button", { name: "Retry freshness check" }),
  );
  await waitFor(() =>
    expect(screen.queryByText("Cannot check for new evidence")).toBeNull(),
  );
  expect(checks).toBe(2);
  expect(screen.getAllByText("12").length).toBeGreaterThan(0);
});

it("withholds configuration comparisons from a different history signature", async () => {
  organization.preferences = [];
  const client = new ApolloClient({
    cache: new InMemoryCache(),
    dataMasking: false,
    link: new MockLink([
      {
        request: { query: RecipeInvestigationDocument, variables: a },
        result: { data: { recipe, analysis: analysis("2", "recipe-version") } },
      },
      {
        request: {
          query: RecipeConfigurationsDocument,
          variables: { context: game.canonicalId, filter: a.filter },
        },
        result: {
          data: { analysis: configurationAnalysis("config-version") },
        },
      },
      {
        request: {
          query: InvestigationSignatureDocument,
          variables: { context: game.canonicalId, filter: a.filter },
        },
        result: { data: { analysisSignature: "recipe-version" } },
      },
      {
        request: {
          query: InvestigationCraftsDocument,
          variables: {
            context: game.canonicalId,
            filter: a.filter,
            after: null,
          },
        },
        result: {
          data: {
            contextCrafts: {
              nodes: [],
              pageInfo: { hasNextPage: false, endCursor: null },
            },
          },
        },
      },
    ]),
  });
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter
          initialEntries={["/retail/recipes/recipe-opaque?period=all"]}
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
    await screen.findByText("Recorded setup evidence changed"),
  ).toBeInTheDocument();
  expect(screen.queryByText("Recorded configurations")).not.toBeInTheDocument();
  expect(screen.getByText("Outcome evidence")).toBeInTheDocument();
});

it.each([
  [18, "forever", "Unsupported Forever filters"],
  [42, "other", "Unsupported Retail-only filters"],
])(
  "requires explicit cleanup of unsupported project %i URL filters without losing A/B scope",
  async (project, routeAlias, title) => {
    const scopedGame: ActiveGame = {
      ...game,
      canonicalId: String(project),
      routeAlias,
      project,
    };
    const calls: {
      name: string | undefined;
      filter: Record<string, unknown> | undefined;
    }[] = [];
    const client = new ApolloClient({
      cache: new InMemoryCache(),
      dataMasking: false,
      link: new ApolloLink(
        (operation) =>
          new Observable((observer) => {
            calls.push({
              name: operation.operationName,
              filter: operation.variables.filter,
            });
            observer.next({
              data:
                operation.operationName === "RecipeInvestigation"
                  ? { recipe, analysis: analysis("2", "same") }
                  : operation.operationName === "RecipeConfigurations"
                    ? { analysis: configurationAnalysis("same") }
                    : operation.operationName === "InvestigationSignature"
                      ? { analysisSignature: "same" }
                      : {
                          contextCrafts: {
                            nodes: [],
                            pageInfo: {
                              hasNextPage: false,
                              endCursor: null,
                            },
                          },
                        },
            });
            observer.complete();
          }),
      ),
    });
    function LocationProbe() {
      return <output data-testid="location">{useLocation().search}</output>;
    }
    render(
      <MantineProvider>
        <ApolloProvider client={client}>
          <MemoryRouter
            initialEntries={[
              `/${routeAlias}/recipes/recipe-opaque?period=all&compare=1&bperiod=all&character=char-a&bcharacter=char-b&returned=item-a&babsentBuff=123&bfinishing=item-b`,
            ]}
          >
            <Routes>
              <Route
                path={`/${routeAlias}/recipes/:id`}
                element={
                  <>
                    <LocationProbe />
                    <Investigation game={scopedGame} kind="recipe" />
                  </>
                }
              />
            </Routes>
          </MemoryRouter>
        </ApolloProvider>
      </MantineProvider>,
    );
    expect(screen.getByText(title)).toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("returned");
    expect(screen.getByRole("alert")).toHaveTextContent("babsentBuff");
    expect(screen.getByRole("alert")).toHaveTextContent("bfinishing");
    expect(calls).toHaveLength(0);
    await userEvent.click(
      screen.getByRole("button", { name: "Clear unsupported filters" }),
    );
    const cleared = screen.getByTestId("location").textContent ?? "";
    expect(cleared).toContain("character=char-a");
    expect(cleared).toContain("bcharacter=char-b");
    expect(cleared).toContain("compare=1");
    expect(cleared).not.toContain("returned=");
    expect(cleared).not.toContain("babsentBuff=");
    expect(cleared).not.toContain("bfinishing=");
    await waitFor(() =>
      expect(
        calls.filter((call) => call.name === "RecipeInvestigation"),
      ).toHaveLength(2),
    );
    expect(
      calls
        .filter((call) => call.name === "RecipeInvestigation")
        .map((call) => call.filter),
    ).toEqual([
      { characterId: "char-a", recipeId: "recipe-opaque" },
      { characterId: "char-b", recipeId: "recipe-opaque" },
    ]);
  },
);

it("compares measured production, return quantities and output quality without averaging partial evidence", async () => {
  organization.preferences = [];
  const first = {
    ...analysis("2", "left"),
    returns: {
      __typename: "AnalysisContributions",
      nodes: [
        {
          id: "reagent-opaque",
          name: "Reagent",
          measure: measure("2", "1"),
        },
      ],
      truncated: false,
    },
    qualities: {
      nodes: [{ quality: 1, measure: measure("2", "2") }],
      truncated: false,
    },
  };
  const second = {
    ...analysis("3", "right"),
    recipes: {
      nodes: [
        {
          ...analysis("3", "right").recipes.nodes[0],
          outputs: measure("3", "9"),
        },
      ],
      truncated: false,
    },
    returns: {
      __typename: "AnalysisContributions",
      nodes: [
        {
          id: "reagent-opaque",
          name: "Reagent",
          measure: {
            ...measure("3", "2.5"),
            measuredAttempts: "2",
            incompleteAttempts: "1",
          },
        },
      ],
      truncated: false,
    },
    qualities: {
      nodes: [{ quality: 2, measure: measure("3", "9") }],
      truncated: false,
    },
  };
  const client = new ApolloClient({
    cache: new InMemoryCache(),
    dataMasking: false,
    link: new MockLink([
      {
        request: {
          query: RecipeConfigurationsDocument,
          variables: { context: game.canonicalId, filter: a.filter },
        },
        result: { data: { analysis: configurationAnalysis("left") } },
      },
      {
        request: {
          query: RecipeConfigurationsDocument,
          variables: { context: game.canonicalId, filter: b.filter },
        },
        result: { data: { analysis: configurationAnalysis("right") } },
      },
      {
        request: { query: RecipeInvestigationDocument, variables: a },
        result: { data: { recipe, analysis: first } },
      },
      {
        request: { query: RecipeInvestigationDocument, variables: b },
        result: { data: { recipe, analysis: second } },
      },
      {
        request: {
          query: InvestigationSignatureDocument,
          variables: { context: game.canonicalId, filter: a.filter },
        },
        result: { data: { analysisSignature: "left" } },
      },
      {
        request: {
          query: InvestigationSignatureDocument,
          variables: { context: game.canonicalId, filter: b.filter },
        },
        result: { data: { analysisSignature: "right" } },
      },
      {
        request: {
          query: InvestigationCraftsDocument,
          variables: {
            context: game.canonicalId,
            filter: a.filter,
            after: null,
          },
        },
        result: {
          data: {
            contextCrafts: {
              nodes: [],
              pageInfo: { hasNextPage: false, endCursor: null },
            },
          },
        },
      },
    ]),
  });
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter
          initialEntries={[
            "/retail/recipes/recipe-opaque?period=all&compare=1&bperiod=all&bcharacter=char-b",
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
    await screen.findByText("Returned material quantities"),
  ).toBeInTheDocument();
  expect(screen.getByText("Output quality evidence")).toBeInTheDocument();
  expect(screen.getByText("Quality 1")).toBeInTheDocument();
  expect(screen.getByText("Quality 2")).toBeInTheDocument();
  expect(screen.getAllByText("1 per measured craft").length).toBeGreaterThan(0);
  expect(screen.getAllByText("3 per measured craft").length).toBeGreaterThan(0);
  expect(screen.getByText("0.5 per measured craft")).toBeInTheDocument();
  expect(
    screen.getByText(
      "Per-craft average unavailable: incomplete observations contribute partial quantities",
    ),
  ).toBeInTheDocument();
  expect(
    screen.getByText("B − A observed rate: −16.7 percentage points"),
  ).toBeInTheDocument();
});

it("keeps hidden recipe contributions in totals without displaying their discovery row", async () => {
  organization.preferences = [{ hidden: true, kind: "Recipe", entityId: 100 }];
  const summary = {
    ...analysis("2", "sig"),
    timeline: {
      nodes: [{ start: "2026-11-07", measure: measure("2", "0") }],
      truncated: false,
    },
  };
  const client = new ApolloClient({
    cache: new InMemoryCache(),
    dataMasking: false,
    link: new MockLink([
      {
        request: {
          query: ActivityInvestigationDocument,
          variables: { context: "1", filter: {}, granularity: "DAY" },
        },
        result: { data: { analysis: summary } },
      },
      {
        request: {
          query: LibraryEntitiesDocument,
          variables: { context: "1", recipeIds: [100], itemIds: [] },
        },
        result: {
          data: {
            game: {
              id: "game",
              canonicalId: "1",
              recipesByBlizzardIds: [recipe],
              itemsByBlizzardIds: [],
            },
          },
        },
      },
    ]),
  });
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter initialEntries={["/retail/activity?period=all"]}>
          <Routes>
            <Route
              path="/retail/activity"
              element={<Investigation game={game} kind="activity" />}
            />
          </Routes>
        </MemoryRouter>
      </ApolloProvider>
    </MantineProvider>,
  );
  expect(
    await screen.findByText("2", { selector: ".metric-value" }),
  ).toBeInTheDocument();
  expect(
    screen.queryByRole("link", { name: "Test recipe" }),
  ).not.toBeInTheDocument();
});

it("keeps item output, gross commitment and returns independently scoped", async () => {
  organization.preferences = [];
  const context = "1",
    id = "item-opaque";
  const common = { recipeId: "recipe-opaque" };
  const role = (field: "outputItemId" | "inputItemId" | "returnedItemId") => ({
    ...common,
    [field]: id,
  });
  const response = {
    item: { id, name: "Test item", blizzardId: 200 },
    relations: {
      signature: "related",
      itemRelations: {
        outputs: {
          nodes: [
            {
              recipeId: "recipe-opaque",
              recipeName: "Test recipe",
              characterId: "char-a",
              characterName: "Crafter",
              measure: measure("2", "12"),
            },
          ],
          truncated: false,
        },
        inputs: { nodes: [], truncated: false },
        returns: { nodes: [], truncated: false },
      },
    },
    produced: {
      signature: "output-sig",
      attempts: measure("2", null),
      outputs: {
        nodes: [
          {
            __typename: "AnalysisContributionGraph",
            id,
            measure: measure("2", "12"),
          },
        ],
        truncated: false,
      },
    },
    committed: {
      signature: "input-sig",
      inputMeasureLabel: "Gross allocated inputs",
      attempts: measure("1", null),
      inputs: {
        nodes: [
          {
            __typename: "AnalysisContributionGraph",
            id,
            measure: measure("1", "5"),
          },
        ],
        truncated: false,
      },
    },
    returned: {
      signature: "return-sig",
      supportsReturns: true,
      attempts: measure("1", null),
      returns: {
        nodes: [
          {
            __typename: "AnalysisContributionGraph",
            id,
            measure: measure("1", "0.5"),
          },
        ],
        truncated: false,
      },
    },
  };
  const client = new ApolloClient({
    cache: createHistoryCache(),
    dataMasking: false,
    link: new MockLink([
      {
        request: {
          query: ItemInvestigationDocument,
          variables: {
            context,
            id,
            relations: { ...common, itemId: id },
            output: role("outputItemId"),
            input: role("inputItemId"),
            returned: role("returnedItemId"),
            retail: true,
          },
        },
        result: { data: response },
      },
      ...[
        [role("outputItemId"), "output-sig"],
        [role("inputItemId"), "input-sig"],
        [role("returnedItemId"), "return-sig"],
      ].map(([filter, signature]) => ({
        request: {
          query: InvestigationSignatureDocument,
          variables: { context, filter },
        },
        result: { data: { analysisSignature: signature } },
      })),
    ]),
  });
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter
          initialEntries={[
            "/retail/items/item-opaque?period=all&recipe=recipe-opaque&input=another",
          ]}
        >
          <Routes>
            <Route
              path="/retail/items/:id"
              element={<Investigation game={game} kind="item" />}
            />
          </Routes>
        </MemoryRouter>
      </ApolloProvider>
    </MantineProvider>,
  );
  expect(
    await screen.findByText("Contributing recipes & characters"),
  ).toBeInTheDocument();
  for (const [heading, quantity] of [
    ["Actual output", "12"],
    ["Gross allocated inputs", "5"],
    ["Recorded returns", "0.5"],
  ] as const) {
    const card = screen
      .getByRole("heading", { name: heading, level: 2 })
      .closest(".mantine-Card-root");
    if (!(card instanceof HTMLElement))
      throw new Error("Missing item role card");
    expect(
      within(card).getByText(quantity, { exact: true }),
    ).toBeInTheDocument();
  }
  const links = screen.getAllByRole("link", {
    name: "Inspect contributing crafts",
  });
  expect(links).toHaveLength(3);
  expect(links[0]).toHaveAttribute(
    "href",
    expect.stringContaining("output=item-opaque"),
  );
  expect(links[0].getAttribute("href")).not.toContain("input=another");
  expect(links[1]).toHaveAttribute(
    "href",
    expect.stringContaining("input=item-opaque"),
  );
  expect(links[2]).toHaveAttribute(
    "href",
    expect.stringContaining("returned=item-opaque"),
  );
  expect(screen.getAllByText("Gross allocated inputs").length).toBeGreaterThan(
    0,
  );
});

it("keeps unknown-project item history without requesting unsupported return analysis", async () => {
  organization.preferences = [];
  const other: ActiveGame = {
    ...game,
    canonicalId: "42",
    routeAlias: "other",
    displayName: "Other project",
    project: 42,
  };
  const id = "item-opaque";
  const client = new ApolloClient({
    cache: new InMemoryCache(),
    dataMasking: false,
    link: new MockLink([
      {
        request: {
          query: ItemInvestigationDocument,
          variables: {
            context: "42",
            id,
            relations: { itemId: id },
            output: { outputItemId: id },
            input: { inputItemId: id },
            returned: { returnedItemId: id },
            retail: false,
          },
        },
        result: {
          data: {
            item: { id, name: "Test item", blizzardId: 200 },
            relations: {
              signature: "related",
              itemRelations: {
                outputs: { nodes: [], truncated: false },
                inputs: { nodes: [], truncated: false },
                returns: null,
              },
            },
            produced: {
              signature: "output-sig",
              attempts: measure("2", null),
              outputs: {
                nodes: [{ id, measure: measure("2", "7") }],
                truncated: false,
              },
            },
            committed: {
              signature: "input-sig",
              inputMeasureLabel: "Recorded input quantities",
              attempts: measure("1", null),
              inputs: {
                nodes: [{ id, measure: measure("1", "3") }],
                truncated: false,
              },
            },
          },
        },
      },
      ...[
        [{ outputItemId: id }, "output-sig"],
        [{ inputItemId: id }, "input-sig"],
      ].map(([filter, signature]) => ({
        request: {
          query: InvestigationSignatureDocument,
          variables: { context: "42", filter },
        },
        result: { data: { analysisSignature: signature } },
      })),
    ]),
  });
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter initialEntries={["/other/items/item-opaque?period=all"]}>
          <Routes>
            <Route
              path="/other/items/:id"
              element={<Investigation game={other} kind="item" />}
            />
          </Routes>
        </MemoryRouter>
      </ApolloProvider>
    </MantineProvider>,
  );
  expect(
    (await screen.findAllByText("Recorded input quantities")).length,
  ).toBeGreaterThan(0);
  expect(
    screen.getAllByRole("link", { name: "Inspect contributing crafts" }),
  ).toHaveLength(2);
  expect(screen.queryByText("Recorded returns")).not.toBeInTheDocument();
  expect(screen.queryByText("Attributed schematic requirements")).toBeNull();
  expect(
    screen.getByText(/consumption without explicit provenance/),
  ).toBeInTheDocument();
});

it("keeps a completed prior-context request out of the new workspace", async () => {
  organization.preferences = [];
  const activity = (attempts: string) => ({
    ...analysis(attempts, attempts),
    timeline: { nodes: [], truncated: false },
    recipes: { nodes: [], truncated: false },
  });
  const client = new ApolloClient({
    cache: new InMemoryCache(),
    dataMasking: false,
    link: new MockLink([
      {
        request: {
          query: ActivityInvestigationDocument,
          variables: { context: "1", filter: {}, granularity: "DAY" },
        },
        delay: 75,
        result: { data: { analysis: activity("9") } },
      },
      {
        request: {
          query: ActivityInvestigationDocument,
          variables: { context: "18", filter: {}, granularity: "DAY" },
        },
        result: {
          data: {
            analysis: {
              ...activity("2"),
              supportsReturns: false,
              returns: null,
              inputMeasureLabel: "Attributed schematic requirements",
            },
          },
        },
      },
    ]),
  });
  function Journey() {
    const [active, setActive] = useState(game);
    return (
      <>
        <button
          onClick={() =>
            setActive({
              ...game,
              canonicalId: "18",
              routeAlias: "forever",
              displayName: "Forever",
              project: 18,
            })
          }
        >
          Switch context
        </button>
        <Investigation game={active} kind="activity" />
      </>
    );
  }
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter initialEntries={["/retail/activity?period=all"]}>
          <Journey />
        </MemoryRouter>
      </ApolloProvider>
    </MantineProvider>,
  );
  await userEvent.click(screen.getByRole("button", { name: "Switch context" }));
  expect(
    await screen.findByText("2", { selector: ".metric-value" }),
  ).toBeInTheDocument();
  await new Promise((resolve) => setTimeout(resolve, 110));
  expect(
    screen.queryByText("9", { selector: ".metric-value" }),
  ).not.toBeInTheDocument();
  expect(
    screen.getAllByText("Attributed schematic requirements").length,
  ).toBeGreaterThan(0);
  expect(screen.queryByText("Observed ingenuity")).not.toBeInTheDocument();
  expect(screen.queryByText("Ingenuity observed rate")).not.toBeInTheDocument();
});

it("labels Forever craft inputs as attributed and omits unsupported Retail outcomes", async () => {
  const forever = {
    ...game,
    canonicalId: "18",
    routeAlias: "forever",
    displayName: "Forever",
    project: 18,
  };
  const craft = {
    id: "craft-id",
    recordedAt: "2026-11-07T12:00:00Z",
    character: { id: "char", name: "Crafter" },
    recipe: null,
    profession: null,
    professionExpansion: null,
    concentrationSpent: null,
    ingenuityRefund: null,
    concentrationCurrencyId: null,
    hasIngenuityProc: null,
    hasResourcefulnessProc: null,
    multicraftBonus: null,
    inputsComplete: null,
    resourcefulnessComplete: null,
    outputsComplete: true,
    reagents: [
      {
        item: { id: "item-id", name: "Reagent", blizzardId: 5 },
        allocatedQuantityExact: "3",
        returnedQuantityExact: null,
      },
    ],
    outputs: [
      {
        item: { id: "output-id", name: "Output", blizzardId: 6 },
        quality: null,
        quantityExact: "9007199254740993",
      },
    ],
    recordedConfigurations: { observed: false, nodes: [], truncated: false },
  };
  const client = new ApolloClient({
    cache: new InMemoryCache(),
    dataMasking: false,
    link: new MockLink([
      {
        request: {
          query: InvestigationCraftDocument,
          variables: { context: "18", id: "craft-id" },
        },
        result: { data: { contextCraft: craft } },
      },
    ]),
  });
  render(
    <MantineProvider>
      <ApolloProvider client={client}>
        <MemoryRouter initialEntries={["/forever/crafts/craft-id?period=all"]}>
          <Routes>
            <Route
              path="/forever/crafts/:id"
              element={<Investigation game={forever} kind="craft" />}
            />
          </Routes>
        </MemoryRouter>
      </ApolloProvider>
    </MantineProvider>,
  );
  expect(await screen.findByText("Attributed requirement")).toBeInTheDocument();
  expect(screen.getByText("9,007,199,254,740,993")).toBeInTheDocument();
  expect(
    screen.getByText(/not supported for Forever crafts/),
  ).toBeInTheDocument();
  expect(screen.queryByText("Gross allocated")).not.toBeInTheDocument();
  expect(screen.queryByText("Returned")).not.toBeInTheDocument();
  expect(screen.queryByText("Concentration spent")).not.toBeInTheDocument();
});
