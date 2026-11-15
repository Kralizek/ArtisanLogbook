import { MantineProvider } from "@mantine/core";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { components } from "../api/generated";
import type { Management, useManagement } from "../api/management";
import { operationsClient } from "../api/clients";
import { Companion } from "./Companion";

vi.mock("../api/clients", () => ({
  operationsClient: { PUT: vi.fn(), POST: vi.fn() },
}));

type SourceResult = components["schemas"]["ImportSourceResult"];
type Operation = components["schemas"]["ImportOperation"];

const sourceId = "src_111111111111111111111111";

function counts(
  overrides: Partial<NonNullable<SourceResult["counts"]>> = {},
): NonNullable<SourceResult["counts"]> {
  return {
    observations: 12,
    inserted: 12,
    alreadyPresent: 0,
    enriched: 0,
    rejectedOrConflicting: 0,
    dimensionsInserted: 1,
    dimensionsEnriched: 0,
    distinctRecipeCount: 3,
    ...overrides,
  };
}

function source(
  id: string,
  gameContexts: string[] | null,
  resultCounts: SourceResult["counts"],
  outcome: SourceResult["outcome"] = "Successful",
): SourceResult {
  return {
    sourceId: id,
    status: outcome === "Successful" ? "Completed" : "Failed",
    outcome,
    counts: resultCounts,
    gameContexts,
    diagnostics: [],
    diagnosticsTruncated: false,
  };
}

function operation(
  id: string,
  sources: SourceResult[],
  outcome: Operation["outcome"] = "Successful",
): Operation {
  return {
    id,
    origin: "Manual",
    status: outcome === "Failed" ? "Failed" : "Completed",
    outcome,
    requestedSourceId: null,
    createdAt: "2026-01-02T00:00:00Z",
    startedAt: "2026-01-02T00:00:01Z",
    completedAt: "2026-01-02T00:00:02Z",
    sources,
    diagnostics: [],
  };
}

function management(
  imports: Operation[],
  overrides = { enabled: false, reconciliationIntervalSeconds: false },
): Management {
  return {
    imports,
    monitoring: {
      state: "Active",
      preferences: { enabled: true, reconciliationIntervalSeconds: 180 },
      effective: { enabled: true, reconciliationIntervalSeconds: 180 },
      overrides,
      pendingSources: 0,
      checkpointSavePending: false,
      diagnostics: [],
      diagnosticsTruncated: false,
    },
    discovery: {
      sources: [
        {
          id: sourceId,
          client: "_retail_",
          fileName: "ArtisanLogbook_Core.lua",
          sizeBytes: 120,
          modifiedAt: null,
        },
        {
          id: "src_222222222222222222222222",
          client: "_classic_",
          fileName: "ArtisanLogbook_Core.lua",
          sizeBytes: 120,
          modifiedAt: null,
        },
      ],
      diagnostics: [],
    },
  };
}

function renderCompanion(data: Management) {
  const state: ReturnType<typeof useManagement> = {
    data,
    error: undefined,
    retry: vi.fn(),
  };
  return {
    ...render(
      <MantineProvider>
        <Companion state={state} />
      </MantineProvider>,
    ),
    state,
  };
}

describe("global Companion receipts", () => {
  beforeEach(() => {
    vi.mocked(operationsClient.PUT).mockReset();
    vi.mocked(operationsClient.POST).mockReset();
    localStorage.clear();
  });

  it("shows distinct recipes rather than attempts, including a successful no-change replay", async () => {
    const user = userEvent.setup();
    renderCompanion(
      management([
        operation("new", [source(sourceId, ["1"], counts())]),
        operation("replayed", [
          source(sourceId, ["1"], counts({ inserted: 0, alreadyPresent: 12 })),
        ]),
      ]),
    );

    await user.click(
      screen.getAllByRole("button", { name: /Manual import/ })[0],
    );
    let row = await screen.findByRole("row", { name: /_retail_.*11111111/ });
    expect(within(row).getAllByRole("cell")[2]).toHaveTextContent("3");
    expect(within(row).getAllByRole("cell")[3]).toHaveTextContent("12");
    expect(row).toHaveTextContent("1");
    await user.click(
      screen.getAllByRole("button", { name: /Manual import/ })[1],
    );
    row = await screen.findByRole("row", { name: /_retail_.*11111111/ });
    expect(within(row).getAllByRole("cell")[1]).toHaveTextContent(
      "Successful · No change",
    );
    expect(within(row).getAllByRole("cell")[2]).toHaveTextContent("3");
    expect(within(row).getAllByRole("cell")[4]).toHaveTextContent("0");
    expect(within(row).getAllByRole("cell")[6]).toHaveTextContent("12");
  });

  it("keeps failed counts unavailable and lists every context despite the remembered analytical context", async () => {
    localStorage.setItem("artisan-logbook.last-context", "1");
    const user = userEvent.setup();
    const retail = source(sourceId, ["1"], counts());
    const forever = source(
      "src_222222222222222222222222",
      ["18"],
      counts({ observations: 4, distinctRecipeCount: 1 }),
    );
    const failed = source(
      "src_333333333333333333333333",
      null,
      counts({ observations: 7, distinctRecipeCount: null }),
      "Rejected",
    );
    const data = management([
      operation("mixed", [retail, forever]),
      operation("failed", [failed], "Failed"),
    ]);
    const { rerender } = renderCompanion(data);

    await user.click(
      screen.getAllByRole("button", { name: /Manual import/ })[0],
    );
    expect(
      await screen.findByRole("row", { name: /_retail_.*11111111/ }),
    ).toHaveTextContent("1");
    expect(
      screen.getByRole("row", { name: /_classic_.*22222222/ }),
    ).toHaveTextContent("18");
    localStorage.setItem("artisan-logbook.last-context", "18");
    rerender(
      <MantineProvider>
        <Companion state={{ data, error: undefined, retry: vi.fn() }} />
      </MantineProvider>,
    );
    expect(
      screen.getByRole("row", { name: /_retail_.*11111111/ }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("row", { name: /_classic_.*22222222/ }),
    ).toBeInTheDocument();

    await user.click(
      screen.getAllByRole("button", { name: /Manual import/ })[1],
    );
    const failedRow = await screen.findByRole("row", {
      name: /Previously discovered source.*33333333/,
    });
    expect(within(failedRow).getAllByRole("cell")[2]).toHaveTextContent(
      "Not available",
    );
    expect(within(failedRow).getAllByRole("cell")[2]).not.toHaveTextContent(
      "0",
    );
    expect(failedRow).toHaveTextContent("Context not established");
  });

  it("preserves the saved interval when toggling monitoring and identifies invocation overrides", async () => {
    const data = management([], {
      enabled: true,
      reconciliationIntervalSeconds: true,
    });
    data.monitoring.effective = {
      enabled: false,
      reconciliationIntervalSeconds: 15,
    };
    vi.mocked(operationsClient.PUT).mockResolvedValue({
      data: data.monitoring,
      response: new Response(),
    } as never);
    const { state } = renderCompanion(data);
    expect(screen.getByText(/Launch options override/)).toBeInTheDocument();
    await userEvent.click(
      screen.getByRole("button", { name: "Disable monitoring" }),
    );
    await waitFor(() =>
      expect(operationsClient.PUT).toHaveBeenCalledWith("/api/v1/monitoring", {
        body: { enabled: false, reconciliationIntervalSeconds: 180 },
      }),
    );
    expect(state.retry).toHaveBeenCalledTimes(1);
    expect(
      screen.getByText(/Invocation overrides still apply/),
    ).toBeInTheDocument();
  });
});
