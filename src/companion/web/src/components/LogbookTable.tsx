import { Badge, Group, Table, Text, Tooltip } from "@mantine/core";
import type { ReactElement, ReactNode } from "react";
import { rawQuantity } from "./analysisFormat";
import { CharacterName } from "./CharacterName";
import { QualityBadge } from "./EntityTooltip";
import {
  craftHighlights,
  shortTime,
  type LogbookCraft,
} from "./logbookHighlights";

/**
 * Total of the known output quantities, exact for integers. An output whose
 * quantity was not recorded is reported as missing, never counted as zero.
 */
function outputTotal(craft: LogbookCraft) {
  if (!craft.outputs) return null;
  const values = craft.outputs
    .map((output) => output.quantityExact)
    .filter((value): value is string => value != null);
  const missing = values.length < craft.outputs.length;
  if (!values.length) return { total: null, missing };
  const total = values.every((value) => /^\d+$/.test(value))
    ? values.reduce((sum, value) => sum + BigInt(value), 0n).toString()
    : String(values.reduce((sum, value) => sum + Number(value), 0));
  return { total, missing };
}

type ItemTooltipRenderer = (
  itemId: string,
  children: ReactElement,
) => ReactNode;

function Result({
  craft,
  itemTooltip,
}: {
  craft: LogbookCraft;
  itemTooltip: ItemTooltipRenderer;
}) {
  if (craft.outputs == null)
    return (
      <Text span c="dimmed">
        Not recorded
      </Text>
    );
  if (!craft.outputs.length)
    return (
      <Text span c="dimmed">
        Nothing produced
      </Text>
    );
  const several = craft.outputs.length > 1;
  return (
    <Group gap={6} wrap="wrap">
      {craft.outputs.map((output, index) => (
        <span
          key={`${output.item.id}-${output.quality ?? ""}-${index}`}
          className="logbook-output"
        >
          {/* Not a link: as in the addon, clicking the result opens the craft. */}
          {itemTooltip(
            output.item.id,
            <span className="logbook-item">
              {output.item.name ?? `Item ${output.item.blizzardId}`}
            </span>,
          )}
          <QualityBadge quality={output.quality} />
          {several && (
            <Text span size="sm" c="dimmed">
              {" "}
              × {rawQuantity(output.quantityExact)}
            </Text>
          )}
        </span>
      ))}
    </Group>
  );
}

/**
 * The Logbook table, laid out like the addon's: recipe, result, character,
 * profession, quantity, highlights, then a compact timestamp opening the craft.
 * A recipe's own history omits the recipe and profession columns.
 */
export function LogbookTable({
  crafts,
  showRecipe = true,
  highlights,
  linkTo,
  itemTooltip = (_itemId, children) => children,
  onOpen,
}: {
  crafts: LogbookCraft[];
  showRecipe?: boolean;
  highlights: boolean;
  linkTo: (destination: string, children: ReactNode) => ReactNode;
  /** Wraps an output item name with its hover details. */
  itemTooltip?: ItemTooltipRenderer;
  /** Opens a craft when its row is clicked outside a link, as in the addon. */
  onOpen?: (craft: LogbookCraft) => void;
}) {
  return (
    <Table.ScrollContainer minWidth={showRecipe ? 900 : 700}>
      <Table highlightOnHover className="logbook-table">
        <Table.Thead>
          <Table.Tr>
            {showRecipe && <Table.Th>Recipe</Table.Th>}
            <Table.Th>Result</Table.Th>
            <Table.Th>Character</Table.Th>
            {showRecipe && <Table.Th>Profession</Table.Th>}
            <Table.Th className="logbook-quantity">Qty</Table.Th>
            {highlights && <Table.Th>Highlights</Table.Th>}
            <Table.Th>Timestamp</Table.Th>
          </Table.Tr>
        </Table.Thead>
        <Table.Tbody>
          {crafts.map((craft) => {
            const measured = outputTotal(craft);
            const total = measured?.total ?? null;
            const partial =
              craft.outputsComplete === false || Boolean(measured?.missing);
            return (
              <Table.Tr
                key={craft.id}
                data-openable={onOpen ? true : undefined}
                onClick={(event) => {
                  // Links and controls inside the row keep their own action.
                  if (
                    onOpen &&
                    !(event.target as HTMLElement).closest("a, button")
                  )
                    onOpen(craft);
                }}
              >
                {showRecipe && (
                  <Table.Td className="logbook-recipe">
                    {craft.recipe?.id ? (
                      linkTo(
                        `recipes/${encodeURIComponent(craft.recipe.id)}`,
                        craft.recipe.name ??
                          `Recipe ${craft.recipe.blizzardId}`,
                      )
                    ) : (
                      <Text span c="dimmed">
                        Unknown recipe
                      </Text>
                    )}
                  </Table.Td>
                )}
                <Table.Td>
                  <Result craft={craft} itemTooltip={itemTooltip} />
                </Table.Td>
                <Table.Td>
                  <CharacterName
                    name={craft.character.name}
                    classFile={craft.character.classFile}
                  />
                </Table.Td>
                {showRecipe && (
                  <Table.Td>
                    {craft.profession?.name ?? (
                      <Text span c="dimmed">
                        Unknown
                      </Text>
                    )}
                  </Table.Td>
                )}
                <Table.Td className="logbook-quantity">
                  {total == null ? (
                    <Text span c="dimmed" aria-label="Quantity not recorded">
                      –
                    </Text>
                  ) : partial ? (
                    <Tooltip
                      label="Some outputs of this craft were not recorded; this counts the known ones."
                      multiline
                      w={260}
                      withArrow
                      events={{ hover: true, focus: true, touch: true }}
                    >
                      <span
                        className="quantity-value"
                        tabIndex={0}
                        aria-label={`${rawQuantity(total)}, partial: some outputs were not recorded`}
                      >
                        {rawQuantity(total)}
                        <span className="partial-mark" aria-hidden>
                          ◐
                        </span>
                      </span>
                    </Tooltip>
                  ) : (
                    rawQuantity(total)
                  )}
                </Table.Td>
                {highlights && (
                  <Table.Td>
                    <Group gap={4} wrap="wrap">
                      {craftHighlights(craft).map((highlight) =>
                        // Concentration is a cost the player chose, not a
                        // proc, so it reads as plain text beside proc chips.
                        highlight.kind === "concentration" ? (
                          <Text
                            key={highlight.kind}
                            span
                            size="xs"
                            c="dimmed"
                            className="craft-concentration"
                            title={highlight.detail}
                          >
                            {highlight.label}
                          </Text>
                        ) : (
                          <Badge
                            key={highlight.kind}
                            size="sm"
                            variant="outline"
                            className="craft-highlight"
                            data-kind={highlight.kind}
                            title={highlight.detail}
                          >
                            {highlight.label}
                          </Badge>
                        ),
                      )}
                    </Group>
                  </Table.Td>
                )}
                <Table.Td className="logbook-time">
                  {linkTo(
                    `crafts/${encodeURIComponent(craft.id)}`,
                    <time
                      dateTime={craft.recordedAt}
                      title={new Date(craft.recordedAt).toLocaleString()}
                    >
                      {shortTime(craft.recordedAt)}
                    </time>,
                  )}
                </Table.Td>
              </Table.Tr>
            );
          })}
        </Table.Tbody>
      </Table>
    </Table.ScrollContainer>
  );
}
