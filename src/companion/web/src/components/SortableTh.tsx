import { Table, UnstyledButton } from "@mantine/core";
import type { ReactNode } from "react";

/** A table header that sorts its column; clicking the active column reverses the direction. */
export function SortableTh({
  children,
  column,
  sort,
  descending,
  onSort,
}: {
  children: ReactNode;
  column: string;
  sort: string;
  descending: boolean;
  onSort: (column: string) => void;
}) {
  const active = column === sort;
  return (
    <Table.Th
      aria-sort={active ? (descending ? "descending" : "ascending") : "none"}
    >
      <UnstyledButton
        className="sortable-header"
        data-active={active || undefined}
        onClick={() => onSort(column)}
      >
        {children}
        <span aria-hidden="true" className="sort-mark">
          {active ? (descending ? "▼" : "▲") : "↕"}
        </span>
      </UnstyledButton>
    </Table.Th>
  );
}
