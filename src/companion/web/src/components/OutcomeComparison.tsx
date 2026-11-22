import { Alert, Table, Text } from "@mantine/core";
import { observedRateDifference } from "./analysisFormat";

export type OutcomeRow = {
  label: string;
  value: string;
  coverage?: string;
  normalized?: string;
  observed?: { positiveAttempts: string; observedAttempts: string };
};

export function OutcomeComparison({
  left,
  right,
}: {
  left: OutcomeRow[];
  right?: OutcomeRow[];
}) {
  return (
    <>
      <Table.ScrollContainer minWidth={right ? 700 : 420}>
        <Table className="analysis-table" striped withTableBorder>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Observed outcome</Table.Th>
              <Table.Th>
                {right ? "Population A" : "Selected population"}
              </Table.Th>
              {right && <Table.Th>Population B</Table.Th>}
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {left.map((row) => {
              const other = right?.find((item) => item.label === row.label);
              return (
                <Table.Tr key={row.label}>
                  <Table.Td>{row.label}</Table.Td>
                  <Table.Td>
                    <Text fw={600}>{row.value}</Text>
                    {row.normalized && <Text size="sm">{row.normalized}</Text>}
                    {row.coverage && (
                      <Text size="xs" c="dimmed">
                        {row.coverage}
                      </Text>
                    )}
                  </Table.Td>
                  {right && (
                    <Table.Td>
                      <Text fw={600}>{other?.value ?? "Not observed"}</Text>
                      {other?.normalized && (
                        <Text size="sm">{other.normalized}</Text>
                      )}
                      {row.observed && other?.observed && (
                        <Text size="sm" c="dimmed">
                          {observedRateDifference(
                            row.observed,
                            other.observed,
                          ) ??
                            "B − A observed rate unavailable (no observed denominator)"}
                        </Text>
                      )}
                      {other?.coverage && (
                        <Text size="xs" c="dimmed">
                          {other.coverage}
                        </Text>
                      )}
                    </Table.Td>
                  )}
                </Table.Tr>
              );
            })}
          </Table.Tbody>
        </Table>
      </Table.ScrollContainer>
      {right && (
        <Alert
          color="blue"
          mt="md"
          title="Historical evidence, not a prediction"
        >
          Compare sample sizes, measurement coverage and recorded setups.
          Differences may reflect other changing factors; they do not establish
          causation or guarantee future outcomes. Higher absolute outcomes and
          greater observed improvement from a resource are different decisions.
        </Alert>
      )}
    </>
  );
}
