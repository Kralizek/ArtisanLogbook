import { Alert, Stack, Table, Text, Title } from "@mantine/core";
import type { RecipeInvestigationQuery } from "../graphql/generated/graphql";
import { exact, observedRateDifference, rate } from "./analysisFormat";

type Characters = RecipeInvestigationQuery["analysis"]["characters"];
type Character = Characters["nodes"][number];

export function CharacterComparison({
  left,
  right,
}: {
  left: Characters;
  right: Characters;
}) {
  const rows = new Map<string, { left?: Character; right?: Character }>();
  for (const row of left.nodes) {
    if (row.id) rows.set(row.id, { left: row });
  }
  for (const row of right.nodes) {
    if (!row.id) continue;
    const pair = rows.get(row.id);
    if (pair) pair.right = row;
    else rows.set(row.id, { right: row });
  }
  const describe = (row: (typeof left.nodes)[number] | undefined) => {
    const outcome = row?.metrics?.ingenuity;
    if (!row) return "No matching population";
    if (!outcome)
      return `${exact(row.measure.attempts)} attempts · not observed`;
    return `${rate(outcome) ?? "Not observed"} · ${exact(outcome.observedAttempts)} observed of ${exact(row.measure.attempts)} attempts`;
  };
  return (
    <Stack gap="xs">
      <Title order={3}>Ingenuity by character across populations</Title>
      <Text size="sm" c="dimmed">
        To investigate a resource, choose its confirmed absence in A and its
        presence in B. Rates use observed attempts; these differences are not
        causal effects.
      </Text>
      <Table.ScrollContainer minWidth={720}>
        <Table striped withTableBorder>
          <Table.Thead>
            <Table.Tr>
              <Table.Th>Character</Table.Th>
              <Table.Th>Population A</Table.Th>
              <Table.Th>Population B</Table.Th>
              <Table.Th>Observed difference</Table.Th>
            </Table.Tr>
          </Table.Thead>
          <Table.Tbody>
            {[...rows.values()].map(({ left: a, right: b }) => (
              <Table.Tr key={a?.id ?? b?.id}>
                <Table.Td>{a?.name ?? b?.name ?? "Unnamed character"}</Table.Td>
                <Table.Td>{describe(a)}</Table.Td>
                <Table.Td>{describe(b)}</Table.Td>
                <Table.Td>
                  {a?.metrics?.ingenuity && b?.metrics?.ingenuity
                    ? (observedRateDifference(
                        a.metrics.ingenuity,
                        b.metrics.ingenuity,
                      ) ?? "Insufficient observed evidence")
                    : "Insufficient observed evidence"}
                </Table.Td>
              </Table.Tr>
            ))}
          </Table.Tbody>
        </Table>
      </Table.ScrollContainer>
      {(left.truncated || right.truncated) && (
        <Alert color="yellow">
          Character lists are truncated; not every population is shown.
        </Alert>
      )}
      {!rows.size && (
        <Text c="dimmed">No identifiable characters in these populations.</Text>
      )}
    </Stack>
  );
}
