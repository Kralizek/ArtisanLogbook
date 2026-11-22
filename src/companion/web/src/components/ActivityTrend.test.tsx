import { MantineProvider } from "@mantine/core";
import { render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { expect, it } from "vitest";
import { ActivityTrend } from "./ActivityTrend";

const game = {
  canonicalId: "1",
  routeAlias: "retail",
  displayName: "Retail",
  project: 1,
  progressionTrack: null,
};

function chart(props: Partial<Parameters<typeof ActivityTrend>[0]>) {
  render(
    <MantineProvider>
      <MemoryRouter>
        <ActivityTrend
          game={game}
          params={new URLSearchParams()}
          points={[]}
          {...props}
        />
      </MemoryRouter>
    </MantineProvider>,
  );
  return screen.getByLabelText("Completed crafts over time");
}

it("draws one column per day of the selected period, leaving unrecorded days empty", () => {
  const bars = chart({
    from: "2026-08-18T00:00:00.000Z",
    to: "2026-11-15T12:00:00.000Z",
    points: [
      { date: "2026-11-07T00:00:00Z", craftCount: "2" },
      { date: "2026-08-18T00:00:00Z", craftCount: "1" },
    ],
  });
  expect(within(bars).getAllByRole("listitem")).toHaveLength(90);
  expect(
    within(bars)
      .getAllByRole("link")
      .map((link) => link.getAttribute("aria-label")),
  ).toEqual([
    "2026-08-18: 1 completed crafts",
    "2026-11-07: 2 completed crafts",
  ]);
  // Empty columns are not fabricated zero observations.
  expect(
    screen
      .getAllByRole("row", { hidden: true })
      .filter((row) => row.closest("tbody")),
  ).toHaveLength(2);
});

it("shows today as a single column", () => {
  expect(
    within(
      chart({
        from: "2026-11-15T00:00:00.000Z",
        to: "2026-11-15T12:00:00.000Z",
        points: [{ date: "2026-11-15", craftCount: "4" }],
      }),
    ).getAllByRole("listitem"),
  ).toHaveLength(1);
});

it("groups weeks from Monday and spans all recorded history through today", () => {
  const bars = chart({
    granularity: "week",
    now: new Date("2026-11-15T12:00:00Z"),
    points: [{ date: "2026-10-26", craftCount: "3" }],
  });
  // Weeks starting 26 Oct, 2 Nov and 9 Nov (15 Nov is a Sunday).
  expect(within(bars).getAllByRole("listitem")).toHaveLength(3);
  expect(within(bars).getByRole("link")).toHaveAttribute(
    "aria-label",
    "2026-10-26 – 2026-11-01: 3 completed crafts",
  );
});
