import { MantineProvider } from "@mantine/core";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { operationsClient } from "../api/clients";
import { SaveInvestigation } from "./SaveInvestigation";
import { SavedInvestigationEntry } from "./SavedInvestigationEntry";

vi.mock("../api/clients", () => ({
  operationsClient: { GET: vi.fn(), POST: vi.fn(), PUT: vi.fn() },
}));

const id = "550e8400-e29b-41d4-a716-446655440000";
const game = {
  canonicalId: "18-Hardcore",
  routeAlias: "18-Hardcore",
  displayName: "Hardcore",
  project: 18,
};
const saved = {
  id,
  name: "Original name",
  context: game.canonicalId,
  revision: 1,
  definitionVersion: 1,
  definition: { destination: "activity", scope: { period: "30" }, query: {} },
  createdAt: "2025-01-01T00:00:00Z",
  updatedAt: "2025-01-01T00:00:00Z",
};
const ok = { status: 200 } as Response;

function Address() {
  const location = useLocation();
  return (
    <p data-testid="address">
      {location.pathname}
      {location.search}
    </p>
  );
}

describe("saved investigation navigation and updates", () => {
  beforeEach(() => {
    vi.mocked(operationsClient.GET).mockReset();
    vi.mocked(operationsClient.POST).mockReset();
    vi.mocked(operationsClient.PUT).mockReset();
  });

  it("uses the REST envelope context and revision when opening a saved definition", async () => {
    vi.mocked(operationsClient.GET).mockImplementation((path) => {
      if (path === "/api/v1/saved-investigations/{id}")
        return Promise.resolve({ data: saved, response: ok }) as never;
      return Promise.resolve({ data: game, response: ok }) as never;
    });
    render(
      <MantineProvider>
        <MemoryRouter initialEntries={[`/saved/${id}`]}>
          <Routes>
            <Route path="/saved/:id" element={<SavedInvestigationEntry />} />
            <Route path="/:context/activity" element={<Address />} />
          </Routes>
        </MemoryRouter>
      </MantineProvider>,
    );
    expect(await screen.findByTestId("address")).toHaveTextContent(
      `/18-Hardcore/activity?period=30&saved=${id}&revision=1`,
    );
    expect(operationsClient.GET).toHaveBeenCalledWith(
      "/api/v1/games/{context}",
      expect.objectContaining({
        params: { path: { context: game.canonicalId } },
      }),
    );
  });

  it("rejects unsupported saved definitions before navigating to analytics", async () => {
    vi.mocked(operationsClient.GET).mockResolvedValue({
      data: { ...saved, definitionVersion: 2 },
      response: ok,
    } as never);
    render(
      <MantineProvider>
        <MemoryRouter initialEntries={[`/saved/${id}`]}>
          <Routes>
            <Route path="/saved/:id" element={<SavedInvestigationEntry />} />
            <Route path="/:context/activity" element={<Address />} />
          </Routes>
        </MemoryRouter>
      </MantineProvider>,
    );
    expect(await screen.findByRole("alert")).toHaveTextContent("not executed");
    expect(screen.queryByTestId("address")).not.toBeInTheDocument();
    expect(operationsClient.GET).toHaveBeenCalledTimes(1);
  });

  it("clears a read error after a successful retry", async () => {
    vi.mocked(operationsClient.GET)
      .mockRejectedValueOnce(new Error("Unavailable"))
      .mockResolvedValueOnce({ data: saved, response: ok } as never);
    render(
      <MantineProvider>
        <MemoryRouter
          initialEntries={[
            `/18-Hardcore/activity?period=30&saved=${id}&revision=1`,
          ]}
        >
          <SaveInvestigation game={game} />
        </MemoryRouter>
      </MantineProvider>,
    );
    await userEvent.click(
      await screen.findByRole("button", { name: /retry/i }),
    );
    expect(
      await screen.findByRole("textbox", { name: "Investigation name" }),
    ).toHaveValue("Original name");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Save changes" })).toBeEnabled();
  });

  it("keeps an edited definition after revision conflict and forks without overwriting", async () => {
    vi.mocked(operationsClient.GET).mockResolvedValue({
      data: saved,
      response: ok,
    } as never);
    vi.mocked(operationsClient.PUT).mockResolvedValue({
      error: { title: "private conflict" },
      response: { status: 409 },
    } as never);
    vi.mocked(operationsClient.POST).mockResolvedValue({
      data: {
        ...saved,
        id: "550e8400-e29b-41d4-a716-446655440001",
        revision: 1,
      },
      response: { status: 201 },
    } as never);
    render(
      <MantineProvider>
        <MemoryRouter
          initialEntries={[
            `/18-Hardcore/activity?period=90&saved=${id}&revision=1`,
          ]}
        >
          <Routes>
            <Route
              path="/:context/activity"
              element={
                <>
                  <SaveInvestigation game={game} />
                  <Address />
                </>
              }
            />
          </Routes>
        </MemoryRouter>
      </MantineProvider>,
    );
    const name = await screen.findByRole("textbox", {
      name: "Investigation name",
    });
    expect(name).toHaveValue("Original name");
    await userEvent.clear(name);
    await userEvent.type(name, "My changed investigation");
    await userEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(
      await screen.findByText(/Save as a copy to keep them/),
    ).toBeInTheDocument();
    expect(name).toHaveValue("My changed investigation");
    await userEvent.click(screen.getByRole("button", { name: "Save as copy" }));
    expect(await screen.findByTestId("address")).toHaveTextContent(
      "period=90&saved=550e8400-e29b-41d4-a716-446655440001&revision=1",
    );
    expect(operationsClient.POST).toHaveBeenCalledWith(
      "/api/v1/games/{context}/saved-investigations",
      expect.objectContaining({
        body: {
          name: "My changed investigation",
          definitionVersion: 1,
          definition: {
            destination: "activity",
            scope: { period: "90" },
            query: {},
          },
        },
      }),
    );
    expect(operationsClient.PUT).toHaveBeenCalledTimes(1);
  });
});
