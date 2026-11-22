import { MantineProvider } from "@mantine/core";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { beforeEach, expect, it, vi } from "vitest";
import { App } from "./App";

const games = vi.hoisted(() => ({
  retail: {
    canonicalId: "1",
    routeAlias: "retail",
    displayName: "Retail",
    project: 1,
    progressionTrack: null,
  },
  forever: {
    canonicalId: "18",
    routeAlias: "forever",
    displayName: "Forever",
    project: 18,
    progressionTrack: null,
  },
}));

const fetchGame = vi.hoisted(() =>
  vi.fn<
    (
      path: string,
      options: { params: { path: { context: string } }; signal: AbortSignal },
    ) => Promise<{ data: typeof games.retail; response: Response }>
  >(),
);

vi.mock("../api/clients", () => ({ operationsClient: { GET: fetchGame } }));
vi.mock("../api/status", () => ({
  OperationalError: class OperationalError extends Error {},
  useStatus: () => ({
    status: {
      state: "Running",
      applicationState: { available: true },
      history: {
        gameContexts: [{ context: games.retail }, { context: games.forever }],
      },
    },
    error: undefined,
    loading: false,
    retry: vi.fn(),
  }),
}));
vi.mock("../api/management", () => ({
  useManagement: () => ({
    data: { monitoring: { state: "Active" }, imports: [] },
    retry: vi.fn(),
  }),
}));
vi.mock("../pages/Companion", () => ({
  Companion: () => <div>Global collection</div>,
}));
vi.mock("../components/ContextSearch", () => ({
  ContextSearch: () => <div>Search history</div>,
}));
vi.mock("../components/PinnedNavigation", () => ({
  PinnedNavigation: () => null,
}));
vi.mock("../pages/Catalogue", () => ({
  Catalogue: () => <div>Catalogue</div>,
}));
vi.mock("../pages/Investigation", () => ({
  Investigation: ({ game }: { game: { displayName: string } }) => (
    <div>Investigating {game.displayName} history</div>
  ),
}));
vi.mock("../organization", () => ({
  EntityPreferencesProvider: ({ children }: { children: React.ReactNode }) =>
    children,
  Library: () => <div>Library</div>,
  SavedInvestigationEntry: () => <div>Saved investigation</div>,
}));

function Location() {
  const location = useLocation();
  return (
    <div data-testid="location">{location.pathname + location.search}</div>
  );
}

function renderApp(initial = "/") {
  return render(
    <MantineProvider env="test">
      <MemoryRouter initialEntries={[initial]}>
        <App />
        <Location />
      </MemoryRouter>
    </MantineProvider>,
  );
}

beforeEach(() => {
  localStorage.clear();
  Element.prototype.scrollIntoView = vi.fn();
  fetchGame.mockReset();
  fetchGame.mockImplementation(async (_path, options) => {
    const locator = options.params.path.context;
    const game =
      locator === "retail" || locator === "1" ? games.retail : games.forever;
    return { data: game, response: new Response(null, { status: 200 }) };
  });
});

it("opens the first recorded context when no context has been remembered", async () => {
  renderApp();
  expect(
    await screen.findByText("Investigating Retail history"),
  ).toBeInTheDocument();
  expect(
    screen.getByRole("combobox", { name: "Active game context" }),
  ).toBeVisible();
});

it("prefers an explicitly qualified URL over a remembered context", async () => {
  localStorage.setItem("artisan-logbook.last-context", "18");
  renderApp("/retail/activity?period=30");
  expect(
    await screen.findByText("Investigating Retail history"),
  ).toBeInTheDocument();
  expect(screen.getByTestId("location")).toHaveTextContent(
    "/retail/activity?period=30",
  );
  await waitFor(() =>
    expect(localStorage.getItem("artisan-logbook.last-context")).toBe("1"),
  );
});

it.each([
  ["18", "Forever"],
  ["unavailable-old-context", "Retail"],
])(
  "resolves remembered context %s without leaving the application blank",
  async (remembered, expected) => {
    localStorage.setItem("artisan-logbook.last-context", remembered);
    renderApp();
    expect(
      await screen.findByText(`Investigating ${expected} history`),
    ).toBeInTheDocument();
  },
);

it("unmounts previous context data while the new context is resolving", async () => {
  const user = userEvent.setup();
  let release:
    | ((value: { data: typeof games.forever; response: Response }) => void)
    | undefined;
  const initial = fetchGame.getMockImplementation()!;
  fetchGame.mockImplementation((path, options) => {
    if (options.params.path.context === "forever" && release)
      return new Promise((resolve) => {
        release = resolve;
      });
    return initial(path, options);
  });
  renderApp("/retail/activity?period=90");
  expect(
    await screen.findByText("Investigating Retail history"),
  ).toBeInTheDocument();
  release = () => {};
  await user.click(
    screen.getByRole("combobox", { name: "Active game context" }),
  );
  await user.click(await screen.findByRole("option", { name: "Forever" }));
  expect(
    await screen.findByLabelText("Resolving game context"),
  ).toBeInTheDocument();
  expect(
    screen.queryByText("Investigating Retail history"),
  ).not.toBeInTheDocument();
  release!({
    data: games.forever,
    response: new Response(null, { status: 200 }),
  });
  expect(
    await screen.findByText("Investigating Forever history"),
  ).toBeInTheDocument();
});

it("changes context from management without leaving global collection", async () => {
  const user = userEvent.setup();
  renderApp("/retail/activity?period=30");
  expect(
    await screen.findByText("Investigating Retail history"),
  ).toBeInTheDocument();
  await user.click(screen.getByRole("link", { name: "Settings" }));
  await user.click(
    screen.getByRole("combobox", { name: "Active game context" }),
  );
  await user.click(await screen.findByRole("option", { name: "Forever" }));
  expect(screen.getByTestId("location")).toHaveTextContent("/companion");
  expect(screen.getByText("Global collection")).toBeInTheDocument();
  await user.click(
    await screen.findByRole("link", { name: "Return to investigation" }),
  );
  expect(
    await screen.findByText("Investigating Forever history"),
  ).toBeInTheDocument();
});
