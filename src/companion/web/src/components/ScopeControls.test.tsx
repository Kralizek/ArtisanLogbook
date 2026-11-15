import { MantineProvider } from "@mantine/core";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { it, expect, vi } from "vitest";
import { ScopeControls } from "./ScopeControls";

vi.mock("@apollo/client/react", () => ({
  useQuery: () => ({ data: undefined, error: undefined }),
}));

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
