import { useEffect, useState } from "react";
import { operationsClient } from "./clients";
import type { paths, components } from "./generated";

export type CompanionStatus =
  paths["/api/v1/status"]["get"]["responses"][200]["content"]["application/json"];

export class OperationalError extends Error {
  readonly status: number;
  readonly problem: components["schemas"]["Problem"];

  constructor(status: number, problem: components["schemas"]["Problem"]) {
    super(`Companion request failed (HTTP ${status}).`);
    this.status = status;
    this.problem = problem;
  }
}

export async function readStatus(
  signal: AbortSignal,
): Promise<CompanionStatus> {
  const { data, error, response } = await operationsClient.GET(
    "/api/v1/status",
    { signal },
  );
  if (error) throw new OperationalError(response.status, error);
  if (!data)
    throw new Error("The Companion returned an invalid status response.");
  return data;
}

export function useStatus() {
  const [status, setStatus] = useState<CompanionStatus>();
  const [error, setError] = useState<Error>();
  const [loading, setLoading] = useState(true);
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let pending = false;
    function refresh() {
      if (
        pending ||
        controller.signal.aborted ||
        document.visibilityState === "hidden"
      )
        return;
      pending = true;
      readStatus(controller.signal)
        .then(
          (value) => {
            if (controller.signal.aborted) return;
            setStatus(value);
            setError(undefined);
            setLoading(false);
          },
          (failure: unknown) => {
            if (controller.signal.aborted) return;
            setError(
              failure instanceof Error
                ? failure
                : new Error("Status request failed."),
            );
            setLoading(false);
          },
        )
        .finally(() => {
          pending = false;
          if (
            !controller.signal.aborted &&
            document.visibilityState !== "hidden"
          )
            timer = setTimeout(refresh, 30_000);
        });
    }
    function visibilityChanged() {
      clearTimeout(timer);
      if (document.visibilityState !== "hidden") refresh();
    }
    document.addEventListener("visibilitychange", visibilityChanged);
    refresh();
    return () => {
      controller.abort();
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", visibilityChanged);
    };
  }, [revision]);
  return {
    status,
    error,
    loading,
    retry() {
      setLoading(true);
      setError(undefined);
      setRevision((value) => value + 1);
    },
  };
}
