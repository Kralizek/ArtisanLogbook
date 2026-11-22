import {
  Accordion,
  Alert,
  Badge,
  Group,
  Stack,
  Table,
  Text,
} from "@mantine/core";
export type ConfigurationEvidence = {
  scope?: string | null;
  statsCoverage?: string | null;
  equipmentCoverage?: string | null;
  buffsCoverage?: string | null;
  finishingCoverage?: string | null;
  useConcentration?: boolean | null;
  statistics?: readonly { label: string; value: string }[] | null;
  equipment?:
    | readonly {
        slot?: number | null;
        itemId?: number | null;
        empty?: boolean | null;
      }[]
    | null;
  buffs?:
    readonly { spellId?: number | null; applications?: number | null }[] | null;
  finishingReagents?:
    readonly { itemId?: number | null; quantity?: number | null }[] | null;
  equipmentTruncated: boolean;
  buffsTruncated: boolean;
  finishingReagentsTruncated: boolean;
};

function observations<T>(
  label: string,
  entries: readonly T[] | null | undefined,
  describe: (row: T) => string,
  truncated: boolean,
) {
  return (
    <Table.Tr>
      <Table.Th scope="row">{label}</Table.Th>
      <Table.Td>
        {entries == null
          ? "Not recorded or incomplete"
          : entries.length
            ? entries.map(describe).join(" · ")
            : "Recorded empty"}
        {truncated && (
          <Text size="xs" c="dimmed">
            Additional recorded entries omitted
          </Text>
        )}
      </Table.Td>
    </Table.Tr>
  );
}

export function AnalysisEvidence({
  evidence,
  available,
}: {
  evidence: ConfigurationEvidence;
  available: boolean;
}) {
  if (!available)
    return (
      <Alert color="yellow">
        Configuration evidence is unavailable to inspect. This recorded variant
        still contributes to the population.
      </Alert>
    );
  return (
    <Stack gap="xs">
      <Text size="sm" c="dimmed">
        Recorded evidence only. Missing selections do not establish that
        equipment, buffs or resources were absent.
      </Text>
      <Group gap="xs">
        {(
          [
            "scope",
            "statsCoverage",
            "equipmentCoverage",
            "buffsCoverage",
            "finishingCoverage",
          ] as const
        ).map((field) => (
          <Badge variant="light" tt="none" key={field}>
            {
              {
                scope: "Scope",
                statsCoverage: "Stats",
                equipmentCoverage: "Equipment",
                buffsCoverage: "Buffs",
                finishingCoverage: "Finishing reagents",
              }[field]
            }
            :{" "}
            {(evidence[field] ?? "unknown").replaceAll("_", " ").toLowerCase()}
          </Badge>
        ))}
      </Group>
      <Table.ScrollContainer minWidth={440}>
        <Table striped withTableBorder>
          <Table.Tbody>
            <Table.Tr>
              <Table.Th scope="row">Concentration selected</Table.Th>
              <Table.Td>
                {evidence.useConcentration == null
                  ? "Unknown"
                  : evidence.useConcentration
                    ? "Yes"
                    : "No"}
              </Table.Td>
            </Table.Tr>
            {observations(
              "Skill and stats",
              evidence.statistics,
              (row) =>
                `${row.label.replaceAll("_", " ")}: ${row.value.replace(/-?\d+\.\d+/g, (value) => Number(value).toLocaleString(undefined, { maximumFractionDigits: 2 }))}`,
              false,
            )}
          </Table.Tbody>
        </Table>
      </Table.ScrollContainer>
      <Accordion>
        <Accordion.Item value="recorded-identifiers">
          <Accordion.Control>
            Equipment, buffs & finishing evidence
          </Accordion.Control>
          <Accordion.Panel>
            <Text size="xs" c="dimmed">
              Recorded identifiers are retained where names were not captured.
              They do not establish undocumented effects.
            </Text>
            <Table.ScrollContainer minWidth={440}>
              <Table>
                <Table.Tbody>
                  {observations(
                    "Equipment",
                    evidence.equipment,
                    (row) =>
                      `Slot ${row.slot ?? "unknown"}: ${row.empty ? "recorded empty" : row.itemId == null ? "unknown item" : `item ${row.itemId}`}`,
                    evidence.equipmentTruncated,
                  )}
                  {observations(
                    "Supported buffs",
                    evidence.buffs,
                    (row) =>
                      `Spell ${row.spellId ?? "unknown"} (${row.applications ?? "unknown"} applications)`,
                    evidence.buffsTruncated,
                  )}
                  {observations(
                    "Submitted finishing reagents",
                    evidence.finishingReagents,
                    (row) =>
                      `Item ${row.itemId ?? "unknown"} × ${row.quantity ?? "unknown"}`,
                    evidence.finishingReagentsTruncated,
                  )}
                </Table.Tbody>
              </Table>
            </Table.ScrollContainer>
          </Accordion.Panel>
        </Accordion.Item>
      </Accordion>
    </Stack>
  );
}
