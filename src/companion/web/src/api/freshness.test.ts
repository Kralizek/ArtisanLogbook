import { act, renderHook } from "@testing-library/react";
import { expect, it } from "vitest";
import { useRetainedResult } from "./freshness";

it("retains detailed evidence until explicitly refreshed, including enrichment without new crafts", () => {
  const old = { signature: "initial", count: "12", returned: null };
  const enriched = { signature: "enriched", count: "12", returned: "2" };
  const hook = renderHook(
    ({ latest }) => useRetainedResult("retail-recipe", latest, false),
    {
      initialProps: {
        latest: old as {
          signature: string;
          count: string;
          returned: string | null;
        },
      },
    },
  );
  hook.rerender({ latest: enriched });
  expect(hook.result.current.result).toEqual(old);
  expect(hook.result.current.changed).toBe(true);
  act(() => hook.result.current.accept(enriched));
  expect(hook.result.current.result).toEqual(enriched);
  expect(hook.result.current.changed).toBe(false);
});

it("never carries cached results into another context and automatically updates summaries", () => {
  const hook = renderHook(
    ({ key, latest }) => useRetainedResult(key, latest, true),
    {
      initialProps: {
        key: "retail",
        latest: { signature: "a", count: "3" } as
          { signature: string; count: string } | undefined,
      },
    },
  );
  hook.rerender({ key: "retail", latest: { signature: "b", count: "4" } });
  expect(hook.result.current.result?.count).toBe("4");
  hook.rerender({ key: "forever", latest: undefined });
  expect(hook.result.current.result).toBeUndefined();
});
