import type { ReactElement } from "react";
import { useQuery } from "@apollo/client/react";
import {
  Badge,
  Group,
  HoverCard,
  Loader,
  Stack,
  Text,
  type FloatingPosition,
} from "@mantine/core";
import type { ActiveGame } from "../app/game";
import {
  ItemTooltipDocument,
  RecipeTooltipDocument,
  type RecipeReagentType,
} from "../graphql/generated/graphql";

export function QualityBadge({ quality }: { quality?: number | null }) {
  if (quality == null) return null;
  return (
    <Badge
      size="xs"
      variant="outline"
      color="yellow"
      ml={4}
      style={{ flexShrink: 0, overflow: "visible" }}
    >
      Quality {quality}
    </Badge>
  );
}

type TooltipProps = {
  game: Pick<ActiveGame, "canonicalId">;
  id: string;
  children: ReactElement;
  position?: FloatingPosition;
};

function EntityHoverCard({
  label,
  children,
  content,
  position = "top-start",
}: {
  label: string;
  children: ReactElement;
  content: () => ReactElement;
  position?: FloatingPosition;
}) {
  return (
    <HoverCard
      width={300}
      openDelay={350}
      closeDelay={100}
      position={position}
      shadow="md"
      role="tooltip"
      withinPortal
    >
      <HoverCard.Target>{children}</HoverCard.Target>
      <HoverCard.Dropdown aria-label={label}>{content()}</HoverCard.Dropdown>
    </HoverCard>
  );
}

function Pending({ error, loading }: { error?: unknown; loading: boolean }) {
  if (loading)
    return (
      <Group gap="xs">
        <Loader size="xs" />
        <Text size="sm">Loading details…</Text>
      </Group>
    );
  return (
    <Text size="sm">
      {error ? "Details are unavailable right now." : "No recorded details."}
    </Text>
  );
}

function ItemDetails({
  game,
  id,
}: {
  game: Pick<ActiveGame, "canonicalId">;
  id: string;
}) {
  const { data, error, loading } = useQuery(ItemTooltipDocument, {
    variables: { context: game.canonicalId, id },
  });
  const item = data?.contextItem;
  if (!item) return <Pending error={error} loading={loading} />;
  return (
    <Stack gap={4}>
      <Group gap={4} wrap="nowrap">
        <Text fw={600} size="sm">
          {item.name ?? `Item ${item.blizzardId}`}
        </Text>
        <QualityBadge quality={item.quality} />
      </Group>
      <Text size="xs" c="dimmed">
        Item #{item.blizzardId}
        {item.name ? "" : " · name not yet recorded"}
      </Text>
      <Text size="xs" c="dimmed">
        Open to see the crafts that used or produced it.
      </Text>
    </Stack>
  );
}

const reagentHeadings: Record<RecipeReagentType, string> = {
  BASIC: "Reagents",
  MODIFYING: "Optional",
  FINISHING: "Finishing",
  AUTOMATIC: "Automatic",
};

type Candidate = {
  id: string;
  blizzardId: number;
  name?: string | null;
  quality?: number | null;
};

function candidateSummary(candidates: readonly Candidate[]) {
  // Quality variants of one reagent share a name; list each name once with its known tiers.
  const byName = new Map<string, number[]>();
  for (const candidate of candidates) {
    const name = candidate.name ?? `Item ${candidate.blizzardId}`;
    const tiers = byName.get(name) ?? [];
    if (candidate.quality != null) tiers.push(candidate.quality);
    byName.set(name, tiers);
  }
  return [...byName]
    .map(([name, tiers]) =>
      tiers.length > 1
        ? `${name} (Quality ${[...new Set(tiers)].sort((a, b) => a - b).join("/")})`
        : name,
    )
    .join(" or ");
}

function RecipeDetails({
  game,
  id,
}: {
  game: Pick<ActiveGame, "canonicalId">;
  id: string;
}) {
  const { data, error, loading } = useQuery(RecipeTooltipDocument, {
    variables: { context: game.canonicalId, id },
  });
  const recipe = data?.contextRecipe;
  if (!recipe) return <Pending error={error} loading={loading} />;
  const context = [recipe.profession?.name, recipe.expansion?.name]
    .filter(Boolean)
    .join(" · ");
  const groups = new Map<string, string[]>();
  for (const slot of recipe.reagentSlots) {
    const candidates = slot.candidateItems ?? [];
    if (!candidates.length) continue;
    const heading = slot.reagentType
      ? reagentHeadings[slot.reagentType]
      : "Reagents";
    const quantity =
      slot.requiredQuantity != null ? `${slot.requiredQuantity} × ` : "";
    const rows = groups.get(heading) ?? [];
    rows.push(`${quantity}${candidateSummary(candidates)}`);
    groups.set(heading, rows);
  }
  return (
    <Stack gap={6}>
      <div>
        <Text fw={600} size="sm">
          {recipe.name ?? `Recipe ${recipe.blizzardId}`}
        </Text>
        {context && (
          <Text size="xs" c="dimmed">
            {context}
          </Text>
        )}
        {recipe.maxQuality != null && (
          <Text size="xs" c="dimmed">
            Up to {recipe.maxQuality} output qualities
          </Text>
        )}
      </div>
      {groups.size === 0 ? (
        <Text size="xs" c="dimmed">
          Reagents have not been recorded for this recipe yet.
        </Text>
      ) : (
        [...groups].map(([heading, rows]) => (
          <div key={heading}>
            <Text size="xs" fw={600}>
              {heading}
            </Text>
            {rows.slice(0, 6).map((row, index) => (
              <Text size="xs" key={index}>
                {row}
              </Text>
            ))}
            {rows.length > 6 && (
              <Text size="xs" c="dimmed">
                and {rows.length - 6} more
              </Text>
            )}
          </div>
        ))
      )}
      <Text size="xs" c="dimmed">
        Recipe #{recipe.blizzardId}
      </Text>
    </Stack>
  );
}

/** Wraps a link to an item with a lazily loaded summary shown on hover or keyboard focus. */
export function ItemTooltip({ game, id, children, position }: TooltipProps) {
  return (
    <EntityHoverCard
      position={position}
      label="Item details"
      content={() => <ItemDetails game={game} id={id} />}
    >
      {children}
    </EntityHoverCard>
  );
}

/** Wraps a link to a recipe with a lazily loaded summary shown on hover or keyboard focus. */
export function RecipeTooltip({ game, id, children, position }: TooltipProps) {
  return (
    <EntityHoverCard
      position={position}
      label="Recipe details"
      content={() => <RecipeDetails game={game} id={id} />}
    >
      {children}
    </EntityHoverCard>
  );
}
