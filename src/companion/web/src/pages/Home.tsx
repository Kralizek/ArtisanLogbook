import { Badge, Card, Group, Loader, Stack, Text, Title } from "@mantine/core";
import type { useStatus } from "../api/status";
import { RequestError } from "../components/RequestError";

export function Home({ state }: { state: ReturnType<typeof useStatus> }) {
  const { status, error, loading, retry } = state;
  const count = status?.history?.craftCount;
  return (
    <Stack>
      <div>
        <Title order={1}>Companion overview</Title>
        <Text c="dimmed">
          Your local crafting history, preserved outside the game.
        </Text>
      </div>
      {loading && <Loader aria-label="Loading Companion status" />}
      {error && <RequestError error={error} retry={retry} />}
      {!loading && !error && status && (
        <Card withBorder padding="lg">
          <Stack>
            <Group justify="space-between">
              <Title order={2}>Canonical history</Title>
              <Badge color={status.state === "Running" ? "teal" : "yellow"}>
                {status.state}
              </Badge>
            </Group>
            <Text size="xl" fw={600}>
              {count == null
                ? "History unavailable"
                : Number.isSafeInteger(count)
                  ? `${count.toLocaleString()} crafts`
                  : "Craft count exceeds exact browser numeric precision"}
            </Text>
            <Text c="dimmed">
              {count === 0
                ? "No history yet. Import a SavedVariables snapshot to get started."
                : count == null
                  ? "The database is not currently available."
                  : "Open Recent crafts to explore recorded observations."}
            </Text>
            <Text size="sm" c="dimmed">
              Application version {status.applicationVersion}
            </Text>
          </Stack>
        </Card>
      )}
    </Stack>
  );
}
