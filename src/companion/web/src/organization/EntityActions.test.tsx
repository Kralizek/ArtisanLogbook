import { MantineProvider } from "@mantine/core";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { operationsClient } from "../api/clients";
import { EntityActions } from "./EntityActions";

vi.mock("../api/clients", () => ({
  operationsClient: { GET: vi.fn(), PUT: vi.fn() },
}));

const game = {
  canonicalId: "18-Hardcore",
  routeAlias: "18-Hardcore",
  displayName: "Hardcore",
  project: 18,
};
const preference = {
  context: game.canonicalId,
  kind: "Recipe" as const,
  entityId: 441,
  pinned: false,
  hidden: true,
};
const response = { status: 200 } as Response;

describe("entity actions", () => {
  beforeEach(() => {
    vi.mocked(operationsClient.GET).mockReset();
    vi.mocked(operationsClient.PUT).mockReset();
  });

  it("persists one desired field without changing the other or changing labels before success", async () => {
    vi.mocked(operationsClient.GET).mockResolvedValue({
      data: { preferences: [preference] },
      response,
    } as never);
    let succeed!: (value: unknown) => void;
    vi.mocked(operationsClient.PUT).mockReturnValue(
      new Promise((resolve) => {
        succeed = resolve;
      }) as never,
    );
    render(
      <MantineProvider>
        <EntityActions game={game} kind="Recipe" blizzardId={441} />
      </MantineProvider>,
    );
    const reveal = await screen.findByRole("button", { name: "Reveal" });
    await userEvent.click(reveal);
    expect(operationsClient.PUT).toHaveBeenCalledWith(
      "/api/v1/games/{context}/entity-preferences/{kind}/{id}/hidden",
      expect.objectContaining({
        params: {
          path: { context: game.canonicalId, kind: "Recipe", id: 441 },
        },
        body: { hidden: false },
      }),
    );
    expect(screen.getByRole("button", { name: "Saving…" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Pin" })).toBeDisabled();
    succeed({ data: { ...preference, hidden: false }, response });
    expect(await screen.findByRole("button", { name: "Hide" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Pin" })).toBeEnabled();
  });

  it("treats a failed preference load as unavailable rather than an empty choice", async () => {
    vi.mocked(operationsClient.GET).mockResolvedValue({
      error: { title: "private details" },
      response: { status: 503 },
    } as never);
    render(
      <MantineProvider>
        <EntityActions game={game} kind="Recipe" blizzardId={441} />
      </MantineProvider>,
    );
    expect(await screen.findByRole("alert")).toHaveTextContent("HTTP 503");
    expect(screen.queryByText("private details")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Pin" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Hide" })).toBeDisabled();
    await waitFor(() => expect(operationsClient.PUT).not.toHaveBeenCalled());
  });

  it("does not claim a pin was saved when its mutation fails", async () => {
    vi.mocked(operationsClient.GET).mockResolvedValue({
      data: { preferences: [preference] },
      response,
    } as never);
    vi.mocked(operationsClient.PUT).mockResolvedValue({
      error: { title: "sensitive failure" },
      response: { status: 503 },
    } as never);
    render(
      <MantineProvider>
        <EntityActions game={game} kind="Recipe" blizzardId={441} />
      </MantineProvider>,
    );
    await userEvent.click(await screen.findByRole("button", { name: "Pin" }));
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Could not save this preference",
    );
    expect(screen.getByRole("button", { name: "Pin" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Reveal" })).toBeEnabled();
    expect(screen.queryByText("sensitive failure")).not.toBeInTheDocument();
  });
});

describe("compact entity actions", () => {
  it("names repeated row controls after their entity", async () => {
    vi.mocked(operationsClient.GET).mockResolvedValue({
      data: { preferences: [{ ...preference, hidden: false, pinned: true }] },
      response,
    } as never);
    render(
      <MantineProvider>
        <EntityActions
          game={game}
          kind="Recipe"
          blizzardId={441}
          compact
          label="Light's Potential"
        />
      </MantineProvider>,
    );
    expect(
      await screen.findByRole("button", { name: "Unpin Light's Potential" }),
    ).toBeEnabled();
    expect(
      screen.getByRole("button", { name: "Hide Light's Potential" }),
    ).toBeInTheDocument();
    expect(screen.queryByText("Loading preferences…")).not.toBeInTheDocument();
  });
});
