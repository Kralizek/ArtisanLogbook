import { MantineProvider } from "@mantine/core";
import { MockedProvider } from "@apollo/client/testing/react";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { expect, it, vi } from "vitest";
import { RecentCraftsDocument } from "../graphql/generated/graphql";
import { App } from "./App";
import { Home } from "../pages/Home";

vi.mock("../api/status", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../api/status")>()),
  useStatus: () => ({
    status: {
      applicationVersion: "test",
      state: "Running",
      database: { available: true, schemaVersion: 1 },
      history: { craftCount: 0, gameContexts: [] },
    },
    error: undefined,
    loading: false,
    retry: vi.fn(),
  }),
}));

it("renders the shell, empty status and navigates to history", async () => {
  render(
    <MantineProvider>
      <MockedProvider
        mocks={[
          {
            request: { query: RecentCraftsDocument, variables: {} },
            result: {
              data: {
                crafts: {
                  nodes: [],
                  pageInfo: { hasNextPage: false, endCursor: null },
                },
              },
            },
          },
        ]}
      >
        <MemoryRouter>
          <App />
        </MemoryRouter>
      </MockedProvider>
    </MantineProvider>,
  );
  expect(screen.getByText("Artisan Logbook")).toBeInTheDocument();
  expect(screen.getByText("0 crafts")).toBeInTheDocument();
  await userEvent.click(screen.getByRole("link", { name: "Recent crafts" }));
  expect(
    await screen.findByText("No recorded crafts yet."),
  ).toBeInTheDocument();
});

it("does not present an unsafe REST count as exact", () => {
  render(
    <MantineProvider>
      <Home
        state={{
          status: {
            applicationVersion: "test",
            state: "Running",
            database: { available: true, schemaVersion: 1 },
            history: {
              craftCount: Number.MAX_SAFE_INTEGER + 1,
              gameContexts: [],
            },
          },
          error: undefined,
          loading: false,
          retry: vi.fn(),
        }}
      />
    </MantineProvider>,
  );
  expect(
    screen.getByText("Craft count exceeds exact browser numeric precision"),
  ).toBeInTheDocument();
});
