import { useState } from "react";
import { useQuery } from "@apollo/client/react";
import {
  Button,
  Group,
  Loader,
  Stack,
  Table,
  Text,
  Title,
} from "@mantine/core";
import { RecentCraftsDocument } from "../graphql/generated/graphql";
import { RequestError } from "../components/RequestError";

export function RecentCrafts() {
  const [after, setAfter] = useState<string>();
  const { data, error, loading, refetch } = useQuery(RecentCraftsDocument, {
    variables: { after },
    errorPolicy: "all",
    notifyOnNetworkStatusChange: true,
  });
  const page = data?.crafts;
  return (
    <Stack>
      <div>
        <Title order={1}>Recent crafts</Title>
        <Text c="dimmed">
          Recorded observations, newest first. Unknown values are not zero.
        </Text>
      </div>
      {error && (
        <RequestError
          error={error}
          retry={() => {
            void refetch();
          }}
        />
      )}
      {loading && <Loader aria-label="Loading recent crafts" />}
      {!loading && page?.nodes.length === 0 && (
        <Text>No recorded crafts yet.</Text>
      )}
      {page && page.nodes.length > 0 && (
        <Table.ScrollContainer minWidth={680}>
          <Table striped highlightOnHover withTableBorder>
            <Table.Thead>
              <Table.Tr>
                <Table.Th>Recorded</Table.Th>
                <Table.Th>Character</Table.Th>
                <Table.Th>Recipe</Table.Th>
                <Table.Th>Profession</Table.Th>
                <Table.Th>Concentration spent</Table.Th>
              </Table.Tr>
            </Table.Thead>
            <Table.Tbody>
              {page.nodes.map((craft) => (
                <Table.Tr key={craft.id}>
                  <Table.Td>
                    <time dateTime={craft.recordedAt}>
                      {new Date(craft.recordedAt).toLocaleString()}
                    </time>
                  </Table.Td>
                  <Table.Td>
                    {craft.character.name ?? `Character ${craft.character.id}`}
                  </Table.Td>
                  <Table.Td>
                    {craft.recipe?.name ??
                      (craft.recipe
                        ? `Recipe ${craft.recipe.blizzardId}`
                        : "Unknown recipe")}
                  </Table.Td>
                  <Table.Td>
                    {craft.profession?.name ??
                      (craft.profession
                        ? `Profession ${craft.profession.blizzardId}`
                        : "Unknown profession")}
                  </Table.Td>
                  <Table.Td>{craft.concentrationSpent ?? "Unknown"}</Table.Td>
                </Table.Tr>
              ))}
            </Table.Tbody>
          </Table>
        </Table.ScrollContainer>
      )}
      <Group>
        <Button
          variant="default"
          disabled={loading || !after}
          onClick={() => setAfter(undefined)}
        >
          Newest
        </Button>
        <Button
          disabled={
            loading || !page?.pageInfo.hasNextPage || !page.pageInfo.endCursor
          }
          onClick={() => {
            if (page?.pageInfo.endCursor) setAfter(page.pageInfo.endCursor);
          }}
        >
          Next page
        </Button>
      </Group>
    </Stack>
  );
}
