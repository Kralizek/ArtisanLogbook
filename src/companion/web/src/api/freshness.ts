import { useState } from "react";

export function useRetainedResult<T extends { signature: string }>(
  key: string,
  latest: T | undefined,
  automatic: boolean,
) {
  const [snapshot, setSnapshot] = useState<{ key: string; result: T }>();
  if (
    latest &&
    (snapshot?.key !== key || (automatic && snapshot.result !== latest))
  ) {
    setSnapshot({ key, result: latest });
  }
  const result =
    automatic && latest
      ? latest
      : snapshot?.key === key
        ? snapshot.result
        : latest;
  return {
    result,
    changed: Boolean(result && latest && result.signature !== latest.signature),
    accept: (next: T) => setSnapshot({ key, result: next }),
  };
}
