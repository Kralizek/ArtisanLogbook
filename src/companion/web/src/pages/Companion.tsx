import { useState } from "react";
import {
  Accordion,
  Alert,
  Badge,
  Button,
  Card,
  Group,
  Loader,
  NumberInput,
  Select,
  Stack,
  Table,
  Text,
  Title,
} from "@mantine/core";
import type { useManagement } from "../api/management";
import { operationsClient } from "../api/clients";
import { OperationalError } from "../api/status";
import { RequestError } from "../components/RequestError";
import type { ActiveGame } from "../app/game";

export function Companion({
  state,
  contexts = [],
}: {
  state: ReturnType<typeof useManagement>;
  contexts?: ActiveGame[];
}) {
  const { data, error, retry } = state;
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<Error>();
  const [notice, setNotice] = useState("");
  const [source, setSource] = useState<string | null>(null);
  const [interval, setInterval] = useState<number | string>();
  async function mutate(
    action: "monitoring" | "import" | "reconcile",
    enabled?: boolean,
  ) {
    setBusy(true);
    setFailure(undefined);
    setNotice("");
    try {
      const result =
        action === "monitoring"
          ? await operationsClient.PUT("/api/v1/monitoring", {
              body: {
                enabled:
                  enabled ?? data?.monitoring.preferences.enabled ?? true,
                reconciliationIntervalSeconds: Number(
                  interval ??
                    data?.monitoring.preferences.reconciliationIntervalSeconds,
                ),
              },
            })
          : action === "import"
            ? await operationsClient.POST("/api/v1/imports", {
                body: source ? { sourceId: source } : {},
              })
            : await operationsClient.POST("/api/v1/monitoring/reconcile", {
                body: {},
              });
      if (result.error)
        throw new OperationalError(result.response.status, result.error);
      setNotice(
        action === "monitoring"
          ? "Monitoring preference saved. Invocation overrides still apply."
          : action === "import"
            ? "Import accepted. Follow its outcome below."
            : "Source reconciliation requested.",
      );
      retry();
    } catch (error) {
      setFailure(
        error instanceof Error ? error : new Error("Operation failed."),
      );
    } finally {
      setBusy(false);
    }
  }
  return (
    <Stack gap="lg">
      <div>
        <Text className="eyebrow">Collection and preservation</Text>
        <Title>Companion</Title>
        <Text c="dimmed">
          Global sources, monitoring and imports. Your analytical context does
          not change these settings.
        </Text>
      </div>
      {error && <RequestError error={error} retry={retry} />}
      {failure && (
        <Alert color="red" title="Operation did not complete">
          The Companion could not apply this request
          {failure instanceof OperationalError
            ? ` (HTTP ${failure.status})`
            : ""}
          . No successful save is implied. Retry after checking diagnostics.
        </Alert>
      )}
      {notice && <Alert color="teal">{notice}</Alert>}
      {!data && !error && <Loader aria-label="Loading Companion management" />}
      {data && (
        <>
          <Card withBorder padding="lg">
            <Group justify="space-between">
              <div>
                <Title order={2}>History collection</Title>
                <Text size="sm" c="dimmed">
                  Current monitoring health is separate from previous import
                  success.
                </Text>
              </div>
              <Badge
                color={
                  data.monitoring.state === "Active"
                    ? "teal"
                    : data.monitoring.state === "Degraded"
                      ? "red"
                      : "gray"
                }
              >
                {data.monitoring.state}
              </Badge>
            </Group>
            <Group mt="md" align="end">
              <NumberInput
                label="Recheck sources every (seconds)"
                min={1}
                max={86400}
                value={
                  interval ??
                  data.monitoring.preferences.reconciliationIntervalSeconds
                }
                onChange={setInterval}
              />
              <Button
                loading={busy}
                onClick={() =>
                  void mutate(
                    "monitoring",
                    !data.monitoring.preferences.enabled,
                  )
                }
              >
                {data.monitoring.preferences.enabled
                  ? "Disable monitoring"
                  : "Enable monitoring"}
              </Button>
              <Button
                variant="default"
                loading={busy}
                onClick={() => void mutate("monitoring")}
              >
                Save interval
              </Button>
              <Button
                variant="light"
                disabled={!data.monitoring.effective.enabled || busy}
                onClick={() => void mutate("reconcile")}
              >
                Check sources now
              </Button>
            </Group>
            <Text mt="sm" size="sm">
              Saved preference:{" "}
              {data.monitoring.preferences.enabled ? "enabled" : "disabled"} ·
              Effective:{" "}
              {data.monitoring.effective.enabled ? "enabled" : "disabled"} ·
              Effective interval:{" "}
              {data.monitoring.effective.reconciliationIntervalSeconds}s
            </Text>
            {(data.monitoring.overrides.enabled ||
              data.monitoring.overrides.reconciliationIntervalSeconds) && (
              <Alert mt="sm" color="yellow">
                Launch options override one or more saved monitoring preferences
                for this session.
              </Alert>
            )}
            {data.monitoring.checkpointSavePending && (
              <Alert mt="sm" color="yellow">
                History was imported, but monitoring acknowledgement still needs
                to be saved.
              </Alert>
            )}
          </Card>
          <Card withBorder padding="lg">
            <Title order={2}>Installations and sources</Title>
            <Text size="sm" c="dimmed" mb="md">
              Sources are discovered from configured installations. A client
              directory is not proof of its recorded game context. To add an
              installation, run <code>artisanlogbook init</code> in a terminal,
              then restart the Companion.
            </Text>
            <Group align="end">
              <Select
                label="SavedVariables source"
                placeholder="All discovered sources"
                clearable
                value={source}
                onChange={setSource}
                data={data.discovery.sources.map((s) => ({
                  value: s.id,
                  label: `${s.client} · ${s.fileName} · ${s.id.slice(-8)}`,
                }))}
                style={{ flex: 1 }}
              />
              <Button
                disabled={!data.discovery.sources.length || busy}
                onClick={() => void mutate("import")}
              >
                Import now
              </Button>
            </Group>
            {!data.discovery.sources.length && (
              <Text mt="md">
                No saved sources found. Configure an installation and save your
                game session first.
              </Text>
            )}
          </Card>
          <div>
            <Group justify="space-between">
              <Title order={2}>Import history</Title>
              <Button variant="subtle" onClick={retry}>
                Refresh status
              </Button>
            </Group>
            <Text size="sm" c="dimmed">
              Recent 100 operations across all contexts. Receipts are retained
              for this running session, not across restarts.
            </Text>
          </div>
          {!data.imports.length && (
            <Text>No import has happened in this Companion session.</Text>
          )}
          <Accordion variant="separated">
            {data.imports.map((operation) => (
              <Accordion.Item key={operation.id} value={operation.id}>
                <Accordion.Control>
                  <Group justify="space-between" pr="md">
                    <Text fw={600}>
                      {new Date(operation.createdAt).toLocaleString()} ·{" "}
                      {operation.origin === "Automatic"
                        ? "Monitoring"
                        : "Manual import"}
                    </Text>
                    <Badge
                      color={
                        operation.outcome === "Failed"
                          ? "red"
                          : operation.outcome === "Partial"
                            ? "yellow"
                            : operation.status === "Completed"
                              ? "teal"
                              : "gray"
                      }
                    >
                      {operation.outcome ?? operation.status}
                    </Badge>
                  </Group>
                </Accordion.Control>
                <Accordion.Panel>
                  <Text size="xs" c="dimmed" mb="sm">
                    Recipes represented = distinct context-qualified recipe
                    identities in accepted observations, including replayed
                    observations; not craft attempts or only newly added
                    recipes.
                  </Text>
                  <Table.ScrollContainer minWidth={650}>
                    <Table>
                      <Table.Thead>
                        <Table.Tr>
                          <Table.Th>Source / context</Table.Th>
                          <Table.Th>Outcome</Table.Th>
                          <Table.Th>Recipes represented</Table.Th>
                          <Table.Th>Recorded attempts</Table.Th>
                          <Table.Th>New</Table.Th>
                          <Table.Th>Enriched</Table.Th>
                          <Table.Th>Already present</Table.Th>
                        </Table.Tr>
                      </Table.Thead>
                      <Table.Tbody>
                        {operation.sources.map((s) => (
                          <Table.Tr key={s.sourceId}>
                            <Table.Td>
                              {data.discovery.sources.find(
                                (v) => v.id === s.sourceId,
                              )?.client ?? "Previously discovered source"}{" "}
                              · {s.sourceId.slice(-8)}
                              <Text size="xs" c="dimmed">
                                {s.gameContexts?.length
                                  ? s.gameContexts
                                      .map(
                                        (id) =>
                                          contexts.find(
                                            (game) => game.canonicalId === id,
                                          )?.displayName ?? id,
                                      )
                                      .join(", ")
                                  : "Context not established"}
                              </Text>
                            </Table.Td>
                            <Table.Td>
                              {s.outcome ?? s.status}
                              {s.counts &&
                              s.counts.inserted === 0 &&
                              s.counts.enriched === 0 &&
                              s.outcome === "Successful"
                                ? " · No change"
                                : ""}
                            </Table.Td>
                            <Table.Td>
                              {s.counts?.distinctRecipeCount ?? "Not available"}
                            </Table.Td>
                            <Table.Td>
                              {s.counts?.observations ?? "Not available"}
                            </Table.Td>
                            <Table.Td>
                              {s.counts?.inserted ?? "Not available"}
                            </Table.Td>
                            <Table.Td>
                              {s.counts?.enriched ?? "Not available"}
                            </Table.Td>
                            <Table.Td>
                              {s.counts?.alreadyPresent ?? "Not available"}
                            </Table.Td>
                          </Table.Tr>
                        ))}
                      </Table.Tbody>
                    </Table>
                  </Table.ScrollContainer>
                  {[
                    ...operation.diagnostics,
                    ...operation.sources.flatMap((s) => s.diagnostics),
                  ].map((d, i) => (
                    <Text key={`${d.code}-${i}`} mt="xs" size="sm">
                      {d.message}
                    </Text>
                  ))}
                </Accordion.Panel>
              </Accordion.Item>
            ))}
          </Accordion>
          <Accordion>
            <Accordion.Item value="diagnostics">
              <Accordion.Control>Collection diagnostics</Accordion.Control>
              <Accordion.Panel>
                <Stack gap="xs">
                  {[
                    ...data.monitoring.diagnostics,
                    ...data.discovery.diagnostics,
                  ].map((d, i) => (
                    <Text size="sm" key={i}>
                      {d.message}
                    </Text>
                  ))}
                  {!data.monitoring.diagnostics.length &&
                    !data.discovery.diagnostics.length && (
                      <Text size="sm">No current collection diagnostics.</Text>
                    )}
                  {data.monitoring.diagnosticsTruncated && (
                    <Text>Additional diagnostics were omitted.</Text>
                  )}
                </Stack>
              </Accordion.Panel>
            </Accordion.Item>
          </Accordion>
        </>
      )}
    </Stack>
  );
}
