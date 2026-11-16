import { MantineProvider } from "@mantine/core";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { components } from "../api/generated";
import {
  clientName,
  type Management,
  type useManagement,
} from "../api/management";
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
    installation: {
      revision: "revision-1",
      configuredRoots: 1,
      activeRoots: 1,
      restartRequired: false,
      candidates: [
        {
          token: "installation_abc",
          label: "Configured installation 1",
          configured: true,
        },
        {
          token: "installation_def",
          label: "Detected installation 2",
          configured: false,
        },
      ],
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
    let row = await screen.findByRole("row", { name: /Retail.*11111111/ });
    expect(within(row).getAllByRole("cell")[2]).toHaveTextContent("3");
    expect(within(row).getAllByRole("cell")[3]).toHaveTextContent("12");
    expect(row).toHaveTextContent("1");
    await user.click(
      screen.getAllByRole("button", { name: /Manual import/ })[1],
    );
    row = await screen.findByRole("row", { name: /Retail.*11111111/ });
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
      await screen.findByRole("row", { name: /Retail.*11111111/ }),
    ).toHaveTextContent("1");
    expect(
      screen.getByRole("row", { name: /Classic.*22222222/ }),
    ).toHaveTextContent("18");
    localStorage.setItem("artisan-logbook.last-context", "18");
    rerender(
      <MantineProvider>
        <Companion state={{ data, error: undefined, retry: vi.fn() }} />
      </MantineProvider>,
    );
    expect(
      screen.getByRole("row", { name: /Retail.*11111111/ }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("row", { name: /Classic.*22222222/ }),
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

  it("uses readable client labels without changing the source identifier submitted for import", async () => {
    expect(clientName("_RETAIL_")).toBe("Retail");
    expect(clientName("_forever_")).toBe("Forever");
    expect(clientName("_classic_")).toBe("Classic");
    expect(clientName("_classic_era_")).toBe("Classic Era");
    expect(clientName("_future_")).toBe("Unknown client (_future_)");
    expect(clientName("../private")).toBe("Unrecognized client");
    const data = management([]);
    data.discovery.sources.push({
      id: "src_333333333333333333333333",
      client: "_future_",
      fileName: "ArtisanLogbook_Core.lua",
      sizeBytes: null,
      modifiedAt: null,
    });
    vi.mocked(operationsClient.POST).mockResolvedValue({
      data: operation("selected", []),
      response: new Response(),
    } as never);
    renderCompanion(data);
    const user = userEvent.setup();
    const sourceSelect = screen.getByRole("combobox", {
      name: "SavedVariables source",
    });
    await user.click(sourceSelect);
    const option = screen
      .getAllByRole("option", { hidden: true })
      .find((node) => node.textContent?.includes("Unknown client (_future_)"));
    expect(option).toBeDefined();
    await user.click(option!);
    expect(sourceSelect).toHaveValue(
      "Unknown client (_future_) · ArtisanLogbook_Core.lua · 33333333",
    );
    await userEvent.click(screen.getByRole("button", { name: "Import now" }));
    await waitFor(() =>
      expect(operationsClient.POST).toHaveBeenCalledWith("/api/v1/imports", {
        body: { sourceId: "src_333333333333333333333333" },
      }),
    );
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
    expect(
      screen.getByText(/cannot change monitoring now/),
    ).toBeInTheDocument();
    await userEvent.click(
      screen.getByRole("button", { name: "Save off for next launch" }),
    );
    await waitFor(() =>
      expect(operationsClient.PUT).toHaveBeenCalledWith("/api/v1/monitoring", {
        body: { enabled: false, reconciliationIntervalSeconds: 180 },
      }),
    );
    expect(state.retry).toHaveBeenCalledTimes(1);
    expect(
      screen.getByText(/Monitoring remains off this session/),
    ).toBeInTheDocument();
  });

  it("enables effective monitoring immediately when no launch option locks it", async () => {
    const data = management([]);
    data.monitoring.preferences.enabled = false;
    data.monitoring.effective.enabled = false;
    data.monitoring.state = "Disabled";
    vi.mocked(operationsClient.PUT).mockResolvedValue({
      data: {
        ...data.monitoring,
        preferences: { ...data.monitoring.preferences, enabled: true },
        effective: { ...data.monitoring.effective, enabled: true },
      },
      response: new Response(),
    } as never);
    renderCompanion(data);
    await userEvent.click(
      screen.getByRole("button", { name: "Turn monitoring on" }),
    );
    await waitFor(() =>
      expect(operationsClient.PUT).toHaveBeenCalledWith("/api/v1/monitoring", {
        body: { enabled: true, reconciliationIntervalSeconds: 180 },
      }),
    );
    expect(
      screen.getByText("Preference saved. Monitoring is on in this session."),
    ).toBeInTheDocument();
  });

  it("shows a custom interval after a preset and preserves the saved interval when toggling monitoring", async () => {
    Element.prototype.scrollIntoView = vi.fn();
    const data = management([]);
    data.monitoring.preferences.reconciliationIntervalSeconds = 3600;
    data.monitoring.effective.reconciliationIntervalSeconds = 3600;
    vi.mocked(operationsClient.PUT).mockResolvedValue({
      data: data.monitoring,
      response: new Response(),
    } as never);
    renderCompanion(data);
    const user = userEvent.setup();
    expect(
      screen.queryByRole("textbox", { name: "Custom interval (seconds)" }),
    ).not.toBeInTheDocument();
    await user.click(
      screen.getByRole("combobox", { name: "Periodic source check" }),
    );
    const customOption = screen
      .getAllByRole("option", { hidden: true })
      .find((option) => option.textContent === "Custom interval");
    expect(customOption).toBeDefined();
    await user.click(customOption!);
    const custom = screen.getByRole("textbox", {
      name: "Custom interval (seconds)",
    });
    expect(custom).toHaveValue("3600");
    expect(
      screen.queryByRole("button", { name: "Increment value" }),
    ).not.toBeInTheDocument();
    await user.clear(custom);
    await user.type(custom, "75");
    await user.click(
      screen.getByRole("button", { name: "Turn monitoring off" }),
    );
    await waitFor(() =>
      expect(operationsClient.PUT).toHaveBeenNthCalledWith(
        1,
        "/api/v1/monitoring",
        { body: { enabled: false, reconciliationIntervalSeconds: 3600 } },
      ),
    );
    await user.click(
      screen.getByRole("button", { name: "Save periodic interval" }),
    );
    await waitFor(() =>
      expect(operationsClient.PUT).toHaveBeenNthCalledWith(
        2,
        "/api/v1/monitoring",
        { body: { enabled: true, reconciliationIntervalSeconds: 75 } },
      ),
    );
  });

  it("offers a browser selection of opaque detected installations and explains the pending restart", async () => {
    const data = management([]);
    data.installation.configuredRoots = 0;
    data.installation.activeRoots = 0;
    data.installation.candidates[0].configured = false;
    data.discovery.sources = [];
    vi.mocked(operationsClient.PUT).mockResolvedValue({
      data: { ...data.installation, configuredRoots: 1, restartRequired: true },
      response: new Response(),
    } as never);
    renderCompanion(data);
    expect(
      screen.getByText(/No SavedVariables sources found/),
    ).toBeInTheDocument();
    await userEvent.click(
      screen.getByRole("checkbox", { name: "Detected installation 2" }),
    );
    await userEvent.click(
      screen.getByRole("button", { name: "Save installations" }),
    );
    await waitFor(() =>
      expect(operationsClient.PUT).toHaveBeenCalledWith(
        "/api/v1/installations",
        {
          body: {
            revision: "revision-1",
            candidateTokens: ["installation_def"],
          },
        },
      ),
    );
    expect(
      screen.getByText(/Restart the Companion to discover sources/),
    ).toBeInTheDocument();
  });

  it("distinguishes a no-change receipt's historical warning summaries from current health", async () => {
    const data = management([
      operation("warnings", [
        {
          ...source(
            sourceId,
            ["1"],
            counts({ inserted: 0, alreadyPresent: 12 }),
          ),
          diagnostics: [
            {
              category: "source",
              code: "reader-warning",
              message:
                "1 warning diagnostic reported while reading the source.",
            },
            {
              category: "coverage",
              code: "aggregate-only",
              message: "1 coverage warning reported.",
            },
          ],
        },
      ]),
    ]);
    renderCompanion(data);
    expect(screen.getByText("No changes")).toBeInTheDocument();
    expect(screen.getByText("2 warning summaries")).toBeInTheDocument();
    await userEvent.click(
      screen.getByRole("button", { name: /Manual import/ }),
    );
    expect(screen.getByText("Historical import warnings")).toBeInTheDocument();
    expect(
      screen.getByText(/aggregate-only: 1 coverage warning reported/),
    ).toBeInTheDocument();
    expect(
      screen.getByText("No current collection diagnostics."),
    ).toBeInTheDocument();
  });
});
