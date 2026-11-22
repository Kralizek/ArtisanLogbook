import {
  Accordion,
  Anchor,
  Group,
  Stack,
  Table,
  Text,
  Title,
} from "@mantine/core";
import { Link } from "react-router";
import type { ActiveGame } from "../app/game";
import { investigationLink } from "../app/scope";

type Granularity = "day" | "week" | "month";

const day = 86400000;

// The UTC start of the day, ISO week (Monday) or month containing a time,
// matching the backend's timeline buckets.
function bucketStart(time: number, granularity: Granularity) {
  const start = new Date(time);
  start.setUTCHours(0, 0, 0, 0);
  if (granularity === "week")
    start.setUTCDate(start.getUTCDate() - ((start.getUTCDay() + 6) % 7));
  if (granularity === "month") start.setUTCDate(1);
  return start.getTime();
}

function nextBucket(start: number, granularity: Granularity) {
  const next = new Date(start);
  if (granularity === "month") next.setUTCMonth(next.getUTCMonth() + 1);
  else next.setUTCDate(next.getUTCDate() + (granularity === "week" ? 7 : 1));
  return next.getTime();
}

const isoDate = (time: number) => new Date(time).toISOString().slice(0, 10);

// Upper bound on generated columns, so an unbounded range cannot render an
// unbounded chart; recorded buckets beyond it are still shown.
const maximumColumns = 3660;

export function ActivityTrend({
  game,
  params,
  points,
  granularity = "day",
  from,
  to,
  now = new Date(),
}: {
  game: ActiveGame;
  params: URLSearchParams;
  points: { date: string; craftCount: string }[];
  granularity?: Granularity;
  /** The investigated period; without it the chart spans the recorded points through today. */
  from?: string | null;
  to?: string | null;
  now?: Date;
}) {
  const recorded = new Map(
    points.map((point) => [point.date.slice(0, 10), BigInt(point.craftCount)]),
  );
  const recordedStarts = [...recorded.keys()].map((date) =>
    Date.parse(`${date}T00:00:00Z`),
  );
  const rangeStart = from
    ? Date.parse(`${from.slice(0, 10)}T00:00:00Z`)
    : recordedStarts.length
      ? Math.min(...recordedStarts)
      : null;
  const rangeEnd = to
    ? Date.parse(`${to.slice(0, 10)}T00:00:00Z`)
    : Math.max(now.getTime(), ...recordedStarts);
  const columns = new Set<string>(recorded.keys());
  if (rangeStart !== null && Number.isFinite(rangeStart)) {
    const last = bucketStart(rangeEnd, granularity);
    for (
      let start = bucketStart(rangeStart, granularity), count = 0;
      start <= last && count < maximumColumns;
      start = nextBucket(start, granularity), count++
    )
      columns.add(isoDate(start));
  }
  const ordered = [...columns].sort();
  const maximum = [...recorded.values()].reduce(
    (max, value) => (value > max ? value : max),
    0n,
  );
  const unit = granularity;
  return (
    <Stack gap="xs">
      <Group justify="space-between">
        <Title order={2}>Crafting activity</Title>
        <Text size="sm" c="dimmed">
          Completed attempts per UTC {unit}
        </Text>
      </Group>
      {!recorded.size ? (
        <Text c="dimmed">No recorded attempts in this scope.</Text>
      ) : (
        <>
          <Group justify="space-between">
            <Text size="xs" c="dimmed">
              Peak: {maximum.toLocaleString()} attempts · {ordered.length}{" "}
              {unit}
              {ordered.length === 1 ? "" : "s"}
            </Text>
            <Text size="xs" c="dimmed">
              Select a bar to inspect that {unit}&apos;s crafts. Empty columns
              have no recorded attempts.
            </Text>
          </Group>
          <div
            className="activity-bars"
            role="list"
            aria-label="Completed crafts over time"
            style={{
              gridTemplateColumns: `repeat(${ordered.length}, minmax(0, 1fr))`,
              columnGap: ordered.length > 120 ? 0 : 2,
            }}
          >
            {ordered.map((date) => {
              const start = Date.parse(`${date}T00:00:00Z`);
              const through = isoDate(nextBucket(start, granularity) - day);
              const range = date === through ? date : `${date} – ${through}`;
              const count = recorded.get(date);
              return (
                <div className="activity-column" role="listitem" key={date}>
                  {count === undefined ? (
                    <span
                      className="activity-empty"
                      title={`${range}: no recorded attempts`}
                    />
                  ) : (
                    <Anchor
                      component={Link}
                      className="activity-bar"
                      style={{
                        height: `${maximum ? Number((count * 1000n) / maximum) / 10 : 0}%`,
                      }}
                      title={`${range}: ${count.toLocaleString()} completed crafts`}
                      aria-label={`${range}: ${count.toLocaleString()} completed crafts`}
                      to={investigationLink(game, "crafts", params, {
                        period: "fixed",
                        from: date,
                        to: through,
                      })}
                    />
                  )}
                </div>
              );
            })}
          </div>
          <Group justify="space-between">
            <Text size="xs" c="dimmed">
              {ordered[0]}
            </Text>
            <Text size="xs" c="dimmed">
              {ordered[ordered.length - 1]}
            </Text>
          </Group>
          <Accordion>
            <Accordion.Item value="table">
              <Accordion.Control>Read activity as a table</Accordion.Control>
              <Accordion.Panel>
                <Table>
                  <Table.Thead>
                    <Table.Tr>
                      <Table.Th>Period starting</Table.Th>
                      <Table.Th>Completed attempts</Table.Th>
                    </Table.Tr>
                  </Table.Thead>
                  <Table.Tbody>
                    {[...recorded]
                      .sort(([a], [b]) => a.localeCompare(b))
                      .map(([date, count]) => (
                        <Table.Tr key={date}>
                          <Table.Td>{date}</Table.Td>
                          <Table.Td>{count.toLocaleString()}</Table.Td>
                        </Table.Tr>
                      ))}
                  </Table.Tbody>
                </Table>
                <Text size="xs" c="dimmed">
                  Only periods with recorded attempts are listed.
                </Text>
              </Accordion.Panel>
            </Accordion.Item>
          </Accordion>
        </>
      )}
    </Stack>
  );
}
