import { MantineProvider } from "@mantine/core";
import { render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { expect, it } from "vitest";
import { ActivityTrend } from "./ActivityTrend";

it("shows recorded periods in chronological order without implying proportional spacing", () => {
  render(
    <MantineProvider>
      <MemoryRouter>
        <ActivityTrend
          game={{
            canonicalId: "1",
            routeAlias: "retail",
            displayName: "Retail",
            project: 1,
            progressionTrack: null,
          }}
          params={new URLSearchParams()}
          points={[
            { date: "2026-11-07", craftCount: "2" },
            { date: "2026-05-15", craftCount: "1" },
          ]}
        />
      </MemoryRouter>
    </MantineProvider>,
  );
  const chart = screen.getByLabelText("Completed crafts over time");
  expect(
    within(chart)
      .getAllByRole("link")
      .map((link) => link.getAttribute("aria-label")),
  ).toEqual([
    "2026-05-15 – 2026-05-15: 1 completed crafts",
    "2026-11-07 – 2026-11-07: 2 completed crafts",
  ]);
  expect(
    screen.getByText(/spacing does not represent elapsed time/),
  ).toBeInTheDocument();
});
