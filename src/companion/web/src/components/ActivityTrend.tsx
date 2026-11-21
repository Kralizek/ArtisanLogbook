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

export function ActivityTrend({
  game,
  params,
  points,
  granularity = "day",
}: {
  game: ActiveGame;
  params: URLSearchParams;
  points: { date: string; craftCount: string }[];
  granularity?: "day" | "week" | "month";
}) {
  const ordered = [...points].sort((a, b) => a.date.localeCompare(b.date));
  const counts = ordered.map((point) => BigInt(point.craftCount));
  const maximum = counts.reduce(
    (max, value) => (value > max ? value : max),
    0n,
  );
  const starts = ordered.map((point) =>
    Date.parse(`${point.date.slice(0, 10)}T00:00:00Z`),
  );
  function periodEnd(start: number) {
    const end = new Date(start);
    if (granularity === "month") end.setUTCMonth(end.getUTCMonth() + 1);
    else end.setUTCDate(end.getUTCDate() + (granularity === "week" ? 7 : 1));
    return end.getTime();
  }
  const first = starts[0] ?? 0;
  const span = starts.length ? periodEnd(starts[starts.length - 1]) - first : 1;
  return (
    <Stack gap="xs">
      <Group justify="space-between">
        <Title order={2}>Crafting activity</Title>
        <Text size="sm" c="dimmed">
          Completed attempts · UTC
        </Text>
      </Group>
      {!ordered.length ? (
        <Text c="dimmed">No recorded attempts in this scope.</Text>
      ) : (
        <>
          <Group justify="space-between">
            <Text size="xs" c="dimmed">
              Peak: {maximum.toLocaleString()} attempts
            </Text>
            <Text size="xs" c="dimmed">
              Open a whole UTC {granularity} to inspect its crafts
              (relative-period edges may include other attempts)
            </Text>
          </Group>
          <Text size="xs" c="dimmed">
            Calendar spacing · gaps mean no recorded period, not confirmed zero
            activity.
          </Text>
          <div
            className="activity-bars"
            aria-label="Completed crafts over time"
          >
            {ordered.map((point, index) => {
              const date = point.date.slice(0, 10);
              const end = new Date(`${date}T00:00:00Z`);
              if (granularity === "week") end.setUTCDate(end.getUTCDate() + 6);
              if (granularity === "month") {
                end.setUTCMonth(end.getUTCMonth() + 1);
                end.setUTCDate(end.getUTCDate() - 1);
              }
              const through = end.toISOString().slice(0, 10);
              return (
                <Anchor
                  component={Link}
                  className="activity-bar"
                  key={point.date}
                  style={{
                    left: `${((starts[index] - first) / span) * 100}%`,
                    width: `${((periodEnd(starts[index]) - starts[index]) / span) * 80}%`,
                    height: `${maximum ? Number((counts[index] * 1000n) / maximum) / 10 : 0}%`,
                    minHeight: counts[index] > 0 ? 3 : 1,
                  }}
                  title={`${date} – ${through}: ${counts[index].toLocaleString()} completed crafts`}
                  aria-label={`${date} – ${through}: ${counts[index].toLocaleString()} completed crafts`}
                  to={investigationLink(game, "crafts", params, {
                    period: "fixed",
                    from: date,
                    to: through,
                  })}
                />
              );
            })}
          </div>
          <Group justify="space-between">
            <Text size="xs" c="dimmed">
              {ordered[0].date.slice(0, 10)}
            </Text>
            <Text size="xs" c="dimmed">
              {ordered[ordered.length - 1].date.slice(0, 10)}
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
                    {ordered.map((point) => (
                      <Table.Tr key={point.date}>
                        <Table.Td>{point.date.slice(0, 10)}</Table.Td>
                        <Table.Td>
                          {BigInt(point.craftCount).toLocaleString()}
                        </Table.Td>
                      </Table.Tr>
                    ))}
                  </Table.Tbody>
                </Table>
              </Accordion.Panel>
            </Accordion.Item>
          </Accordion>
        </>
      )}
    </Stack>
  );
}
