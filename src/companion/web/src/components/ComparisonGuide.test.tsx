import { MantineProvider } from "@mantine/core";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router";
import { beforeEach, expect, it, vi } from "vitest";
import { ComparisonGuide } from "./ComparisonGuide";

vi.mock("@apollo/client/react", () => ({
  useQuery: () => ({
    data: {
      game: {
        characters: {
          nodes: [
            { id: "char-a", name: "Aria" },
            { id: "char-b", name: "Bran" },
          ],
        },
        itemsByBlizzardIds: [
          {
            id: "opaque-finishing",
            blizzardId: 55,
            name: "Recorded finishing reagent",
          },
        ],
      },
    },
    refetch: vi.fn(),
  }),
}));
vi.mock("./ScopeControls", () => ({ ScopeControls: () => null }));
beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
});
const game = {
  canonicalId: "1",
  routeAlias: "retail",
  displayName: "Retail",
  project: 1,
  progressionTrack: null,
};
function Address() {
  return <output data-testid="address">{useLocation().search}</output>;
}
function show(search: string) {
  render(
    <MantineProvider env="test">
      <MemoryRouter initialEntries={[`/${search}`]}>
        <ComparisonGuide
          game={game}
          configurations={[]}
          finishingIds={[55]}
          buffIds={[123]}
        />
        <Address />
      </MemoryRouter>
    </MantineProvider>,
  );
}

it("builds a with/without comparison using canonical item identities and preserves common evidence filters", async () => {
  const user = userEvent.setup();
  show("?period=all&buff=123&after=old");
  await user.click(
    screen.getByRole("combobox", { name: "What would you like to compare?" }),
  );
  await user.click(
    screen.getByRole("option", {
      name: "With and without a finishing reagent",
    }),
  );
  await user.click(
    screen.getByRole("combobox", { name: "Recorded finishing reagent" }),
  );
  await user.click(
    screen.getByRole("option", { name: "Recorded finishing reagent · #55" }),
  );
  await user.click(screen.getByRole("button", { name: "Compare setups" }));
  const params = new URLSearchParams(
    screen.getByTestId("address").textContent ?? "",
  );
  expect(params.get("absentFinishing")).toBe("opaque-finishing");
  expect(params.get("bfinishing")).toBe("opaque-finishing");
  expect(params.get("buff")).toBe("123");
  expect(params.get("bbuff")).toBe("123");
  expect(params.get("bperiod")).toBe("all");
  expect(params.has("after")).toBe(false);
  expect(params.has("finishing")).toBe(false);
});

it("removes only comparison state without deleting the primary buff filter", async () => {
  show("?period=30&buff=123&compare=1&bperiod=90&bbuff=456&bcharacter=char-b");
  await userEvent.click(
    screen.getByRole("button", { name: "Remove comparison" }),
  );
  const params = new URLSearchParams(
    screen.getByTestId("address").textContent ?? "",
  );
  expect(params.get("buff")).toBe("123");
  expect(params.has("bbuff")).toBe(false);
  expect(params.has("compare")).toBe(false);
  expect(params.has("bcharacter")).toBe(false);
});

it("keeps an existing custom population instead of offering to overwrite it from A", () => {
  show("?period=30&compare=1&bperiod=all&bcharacter=char-b");
  expect(
    screen.queryByRole("button", { name: "Apply comparison question" }),
  ).not.toBeInTheDocument();
  const params = new URLSearchParams(
    screen.getByTestId("address").textContent ?? "",
  );
  expect(params.get("bperiod")).toBe("all");
  expect(params.get("bcharacter")).toBe("char-b");
});
