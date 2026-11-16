import { useState } from "react";
import {
  Accordion,
  Alert,
  Badge,
  Button,
  Card,
  Checkbox,
  Group,
  Loader,
  NumberInput,
  Select,
  Stack,
  Table,
  Text,
  Title,
} from "@mantine/core";
import { clientName, type useManagement } from "../api/management";
import { operationsClient } from "../api/clients";
import { OperationalError } from "../api/status";
import { RequestError } from "../components/RequestError";
import type { ActiveGame } from "../app/game";

const intervalPresets = [
  { value: "900", label: "Every 15 minutes" },
  { value: "3600", label: "Every hour" },
  { value: "21600", label: "Every 6 hours" },
];

function duration(seconds: number): string {
  if (seconds % 3600 === 0)
    return `${seconds / 3600} ${seconds === 3600 ? "hour" : "hours"}`;
  if (seconds % 60 === 0)
    return `${seconds / 60} ${seconds === 60 ? "minute" : "minutes"}`;
  return `${seconds} seconds`;
}

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
  const [intervalMode, setIntervalMode] = useState<string | null>(null);
  const [customInterval, setCustomInterval] = useState<number | string>();
  const [selectedCandidates, setSelectedCandidates] = useState<string[] | null>(
    null,
  );
  const savedInterval =
    data?.monitoring.preferences.reconciliationIntervalSeconds;
  const intervalChoice =
    intervalMode ??
    (intervalPresets.some((preset) => preset.value === String(savedInterval))
      ? String(savedInterval)
      : "custom");
  const selectedInterval =
    intervalChoice === "custom"
      ? (customInterval ?? savedInterval)
      : Number(intervalChoice);
  const lockedEnabled = data?.monitoring.overrides.enabled ?? false;
  const validInterval =
    Number.isInteger(Number(selectedInterval)) &&
    Number(selectedInterval) >= 1 &&
    Number(selectedInterval) <= 86400;
  const sourceName = (id: string) => {
    const client = data?.discovery.sources.find(
      (value) => value.id === id,
    )?.client;
    return client ? clientName(client) : "Previously discovered source";
  };
  async function mutate(
    action: "monitoring" | "import" | "reconcile" | "installations",
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
                reconciliationIntervalSeconds:
                  enabled === undefined
                    ? Number(selectedInterval)
                    : data!.monitoring.preferences
                        .reconciliationIntervalSeconds,
              },
            })
          : action === "installations"
            ? await operationsClient.PUT("/api/v1/installations", {
                body: {
                  revision: data!.installation.revision,
                  candidateTokens:
                    selectedCandidates ??
                    data!.installation.candidates
                      .filter((candidate) => candidate.configured)
                      .map((candidate) => candidate.token),
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
          ? result.data && "effective" in result.data
            ? result.data.overrides.enabled
              ? `Preference saved. Monitoring remains ${result.data.effective.enabled ? "on" : "off"} this session because of a launch option.`
              : `Preference saved. Monitoring is ${result.data.effective.enabled ? "on" : "off"} in this session.`
            : "Monitoring preference saved."
          : action === "installations"
            ? result.data &&
              "restartRequired" in result.data &&
              result.data.restartRequired
              ? "Installation selection saved. Restart the Companion to discover sources from the newly selected roots; this session still uses its startup installations."
              : "Installation selection saved. Active installations are unchanged."
            : action === "import"
              ? "Import accepted. Follow its outcome below."
              : "Source reconciliation requested. This checks configured sources; it does not directly import an already-known unchanged source.",
      );
      if (action === "installations") setSelectedCandidates(null);
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
        <Title>Settings</Title>
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
      {notice && <Alert color="green">{notice}</Alert>}
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
                    ? "green"
                    : data.monitoring.state === "Degraded"
                      ? "red"
                      : "gray"
                }
              >
                {data.monitoring.state}
              </Badge>
            </Group>
            <Text mt="md" size="sm">
              Monitoring is{" "}
              <strong>
                {data.monitoring.effective.enabled ? "on" : "off"}
              </strong>{" "}
              in this session. Your saved preference is{" "}
              {data.monitoring.preferences.enabled ? "on" : "off"}.
            </Text>
            {lockedEnabled && (
              <Alert mt="sm" color="yellow">
                A launch option forces monitoring{" "}
                {data.monitoring.effective.enabled ? "on" : "off"} in this
                session. You can save a preference for a future launch, but
                cannot change monitoring now.
              </Alert>
            )}
            <Group mt="md" align="end">
              <Select
                label="Periodic source check"
                value={intervalChoice}
                onChange={setIntervalMode}
                data={[
                  ...intervalPresets,
                  { value: "custom", label: "Custom interval" },
                ]}
              />
              {intervalChoice === "custom" && (
                <NumberInput
                  label="Custom interval (seconds)"
                  min={1}
                  max={86400}
                  hideControls
                  value={customInterval ?? savedInterval}
                  onChange={setCustomInterval}
                />
              )}
              <Button
                loading={busy}
                disabled={busy}
                onClick={() =>
                  void mutate(
                    "monitoring",
                    !data.monitoring.preferences.enabled,
                  )
                }
              >
                {lockedEnabled
                  ? `Save ${data.monitoring.preferences.enabled ? "off" : "on"} for next launch`
                  : data.monitoring.preferences.enabled
                    ? "Turn monitoring off"
                    : "Turn monitoring on"}
              </Button>
              <Button
                variant="default"
                loading={busy}
                disabled={!validInterval || busy}
                onClick={() => void mutate("monitoring")}
              >
                Save periodic interval
              </Button>
              <Button
                variant="light"
                disabled={!data.monitoring.effective.enabled || busy}
                onClick={() => void mutate("reconcile")}
              >
                Recheck configured sources
              </Button>
            </Group>
            <Text mt="sm" size="sm" c="dimmed">
              Full fallback check: every{" "}
              {duration(
                data.monitoring.effective.reconciliationIntervalSeconds,
              )}
              {data.monitoring.overrides.reconciliationIntervalSeconds
                ? " (set by a launch option; saved changes apply on a future launch)"
                : ""}
              . File watchers normally trigger timely imports between periodic
              checks. Missed events or unavailable watchers can take up to the
              fallback interval to be noticed.
            </Text>
            <Text size="sm" c="dimmed">
              Rechecking asks enabled monitoring to look for changed sources;
              manual import below submits an import of a selected source even
              when monitoring is off.
            </Text>
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
              Choose a detected WoW installation below, then restart the
              Companion to make the saved selection active. Detection checks
              standard locations only; for another location use{" "}
              <code>artisanlogbook init</code> in a terminal. The Companion
              never edits game files. A client folder does not establish the
              GameContext recorded inside a source.
            </Text>
            <Text size="sm">
              {data.installation.configuredRoots} saved{" "}
              {data.installation.configuredRoots === 1
                ? "installation"
                : "installations"}
              {" · "}
              {data.installation.activeRoots} active this session
              {" · "}
              {data.discovery.sources.length} discovered{" "}
              {data.discovery.sources.length === 1 ? "source" : "sources"}
            </Text>
            {data.installation.restartRequired && (
              <Alert mt="sm" color="yellow" title="Restart needed">
                Saved installations differ from the roots used by this running
                Companion. Restart it before expecting new sources or automatic
                imports.
              </Alert>
            )}
            {data.installation.candidates.length > 0 ? (
              <>
                <Checkbox.Group
                  mt="sm"
                  label="WoW installations"
                  description="Only installations found by the Companion are offered; no filesystem browsing or path entry."
                  value={
                    selectedCandidates ??
                    data.installation.candidates
                      .filter((candidate) => candidate.configured)
                      .map((candidate) => candidate.token)
                  }
                  onChange={setSelectedCandidates}
                >
                  <Stack gap="xs" mt="xs">
                    {data.installation.candidates.map((candidate) => (
                      <Checkbox
                        key={candidate.token}
                        value={candidate.token}
                        label={candidate.label}
                      />
                    ))}
                  </Stack>
                </Checkbox.Group>
                <Button
                  mt="sm"
                  variant="light"
                  loading={busy}
                  disabled={selectedCandidates === null}
                  onClick={() => void mutate("installations")}
                >
                  Save installations
                </Button>
              </>
            ) : (
              <Text mt="sm" size="sm">
                No installations detected in standard locations. Use{" "}
                <code>artisanlogbook init</code> to configure an installation
                elsewhere, then restart.
              </Text>
            )}
            {data.discovery.sources.length > 0 && (
              <Text mt="sm" size="sm">
                Available sources:{" "}
                {data.discovery.sources
                  .map((s) => `${clientName(s.client)} (${s.id.slice(-8)})`)
                  .join(", ")}
                .
              </Text>
            )}
            <Group align="end">
              <Select
                label="SavedVariables source"
                placeholder="All discovered sources"
                clearable
                clearButtonProps={{ "aria-label": "Clear import source" }}
                value={source}
                onChange={setSource}
                data={data.discovery.sources.map((s) => ({
                  value: s.id,
                  label: `${clientName(s.client)} · ${s.fileName} · ${s.id.slice(-8)}`,
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
                No SavedVariables sources found in active installations. After
                setup and restart, save your game session to create a source.
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
            {data.imports.map((operation) => {
              const warnings = [
                ...operation.diagnostics,
                ...operation.sources.flatMap((s) => s.diagnostics),
              ];
              const noChanges =
                operation.outcome === "Successful" &&
                operation.sources.length > 0 &&
                operation.sources.every(
                  (s) =>
                    s.outcome === "Successful" &&
                    s.counts?.inserted === 0 &&
                    s.counts?.enriched === 0,
                );
              return (
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
                                ? "green"
                                : "gray"
                        }
                      >
                        {operation.outcome ?? operation.status}
                      </Badge>
                      {noChanges && <Badge color="gray">No changes</Badge>}
                      {warnings.length > 0 && (
                        <Badge color="yellow">
                          {warnings.length}{" "}
                          {operation.outcome === "Successful"
                            ? "warning"
                            : "diagnostic"}{" "}
                          {warnings.length === 1 ? "summary" : "summaries"}
                        </Badge>
                      )}
                    </Group>
                  </Accordion.Control>
                  <Accordion.Panel>
                    {warnings.length > 0 && (
                      <Alert
                        color="yellow"
                        title={
                          operation.outcome === "Successful"
                            ? "Historical import warnings"
                            : "Historical import diagnostics"
                        }
                        mb="sm"
                      >
                        This completed import reported {warnings.length}{" "}
                        diagnostic{" "}
                        {warnings.length === 1 ? "summary" : "summaries"}.
                        Detailed individual warnings are not retained in this
                        receipt. These are historical import results, not
                        current collection health.
                        <Stack gap="xs" mt="xs">
                          {warnings.map((warning, index) => (
                            <Text key={`${warning.code}-${index}`} size="sm">
                              {warning.category} · {warning.code}:{" "}
                              {warning.message}
                            </Text>
                          ))}
                        </Stack>
                        {operation.sources.some(
                          (s) => s.diagnosticsTruncated,
                        ) && (
                          <Text size="sm">
                            Additional diagnostics were omitted.
                          </Text>
                        )}
                      </Alert>
                    )}
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
                                {sourceName(s.sourceId)} ·{" "}
                                {s.sourceId.slice(-8)}
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
                                {s.counts?.distinctRecipeCount ??
                                  "Not available"}
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
                  </Accordion.Panel>
                </Accordion.Item>
              );
            })}
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
