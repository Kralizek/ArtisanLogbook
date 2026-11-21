import { MantineProvider } from "@mantine/core";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { beforeEach, it, expect, vi } from "vitest";
import { WorkspaceSelectedItemDocument } from "../graphql/generated/graphql";
import { ScopeControls } from "./ScopeControls";

const query = vi.hoisted(() =>
  vi.fn<
    (document: unknown) => {
      data: unknown;
      error: undefined;
    }
  >(() => ({ data: undefined, error: undefined })),
);
vi.mock("@apollo/client/react", () => ({
  useQuery: query,
}));
beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
});

function Address() {
  return <output data-testid="scope-address">{useLocation().search}</output>;
}

it.each(["", "b"])(
  "clears inactive fixed bounds for relative periods in population %s",
  async (prefix) => {
    const user = userEvent.setup();
    render(
      <MantineProvider env="test">
        <MemoryRouter
          initialEntries={[
            `/?${prefix}period=fixed&${prefix}from=2026-01-01&${prefix}to=2026-02-01`,
          ]}
        >
          <ScopeControls
            game={{
              canonicalId: "1",
              routeAlias: "retail",
              displayName: "Retail",
              project: 1,
              progressionTrack: null,
            }}
            prefix={prefix}
          />
          <Address />
        </MemoryRouter>
      </MantineProvider>,
    );
    await user.click(
      screen.getByRole("combobox", {
        name: `${prefix ? "Population B " : ""}Period`,
      }),
    );
    await user.click(screen.getByRole("option", { name: "Last 30 days" }));
    expect(screen.getByTestId("scope-address")).toHaveTextContent(
      `${prefix}period=30`,
    );
    expect(screen.getByTestId("scope-address")).not.toHaveTextContent("from=");
    expect(screen.getByTestId("scope-address")).not.toHaveTextContent("to=");
  },
);

it("offers advanced Retail filters progressively", async () => {
  render(
    <MantineProvider env="test">
      <MemoryRouter>
        <ScopeControls
          game={{
            canonicalId: "1",
            routeAlias: "retail",
            displayName: "Retail",
            project: 1,
            progressionTrack: null,
          }}
        />
      </MemoryRouter>
    </MantineProvider>,
  );
  expect(
    screen.queryByRole("combobox", { name: "Returned item" }),
  ).not.toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "More filters" }));
  expect(
    await screen.findByRole("combobox", { name: "Returned item" }),
  ).toBeVisible();
});

it("resolves a restored item filter to its recorded name", () => {
  query.mockImplementation((document) =>
    document === WorkspaceSelectedItemDocument
      ? {
          data: {
            contextItem: { id: "item-id", name: "Test reagent", blizzardId: 7 },
          },
          error: undefined,
        }
      : { data: undefined, error: undefined },
  );
  try {
    render(
      <MantineProvider env="test">
        <MemoryRouter initialEntries={["/?absentFinishing=item-id"]}>
          <ScopeControls
            game={{
              canonicalId: "1",
              routeAlias: "retail",
              displayName: "Retail",
              project: 1,
              progressionTrack: null,
            }}
          />
        </MemoryRouter>
      </MantineProvider>,
    );
    expect(
      screen.getByRole("combobox", { name: "Absent submitted finishing item" }),
    ).toHaveValue("Test reagent · #7");
  } finally {
    query.mockReset();
    query.mockReturnValue({ data: undefined, error: undefined });
  }
});

it("offers the backend game-expansion population while retaining explicit legacy filters separately", async () => {
  query.mockReturnValue({
    data: {
      game: {
        characters: { nodes: [], pageInfo: { hasNextPage: false } },
        professions: { nodes: [], pageInfo: { hasNextPage: false } },
        items: { nodes: [] },
        expansions: {
          nodes: [
            {
              id: "exact-profession-key",
              key: "skillLine:2906",
              name: "Midnight",
            },
          ],
          pageInfo: { hasNextPage: false },
        },
        expansionGroups: {
          nodes: [
            {
              id: "all-midnight-professions",
              key: "game:midnight",
              name: "Midnight",
            },
          ],
          truncated: false,
        },
      },
    },
    error: undefined,
  });
  try {
    const user = userEvent.setup();
    render(
      <MantineProvider env="test">
        <MemoryRouter initialEntries={["/?expansion=exact-profession-key"]}>
          <ScopeControls
            game={{
              canonicalId: "1",
              routeAlias: "retail",
              displayName: "Retail",
              project: 1,
              progressionTrack: null,
            }}
          />
          <Address />
        </MemoryRouter>
      </MantineProvider>,
    );
    expect(
      screen.getByRole("combobox", { name: "Legacy profession expansion" }),
    ).toHaveValue("Midnight");
    await user.click(screen.getByRole("combobox", { name: "Game expansion" }));
    await user.click(screen.getByRole("option", { name: "Midnight" }));
    expect(screen.getByTestId("scope-address")).toHaveTextContent(
      "gameExpansion=all-midnight-professions",
    );
    expect(screen.getByTestId("scope-address")).toHaveTextContent(
      "expansion=exact-profession-key",
    );
  } finally {
    query.mockReturnValue({ data: undefined, error: undefined });
  }
});

it.each([
  {
    canonicalId: "18",
    routeAlias: "forever",
    displayName: "Forever",
    project: 18,
  },
  {
    canonicalId: "5",
    routeAlias: "5",
    displayName: "Other project",
    project: 5,
  },
])("omits unsupported Retail filters in $displayName", async (game) => {
  render(
    <MantineProvider env="test">
      <MemoryRouter>
        <ScopeControls game={{ ...game, progressionTrack: null }} />
      </MemoryRouter>
    </MantineProvider>,
  );
  await userEvent.click(screen.getByRole("button", { name: "More filters" }));
  expect(
    await screen.findByRole("combobox", { name: "Input item" }),
  ).toBeVisible();
  expect(
    screen.queryByRole("combobox", { name: "Returned item" }),
  ).not.toBeInTheDocument();
  expect(
    screen.queryByRole("textbox", { name: "Recorded buff spell ID" }),
  ).not.toBeInTheDocument();
  expect(
    screen.queryByRole("combobox", { name: "Finishing item" }),
  ).not.toBeInTheDocument();
});
