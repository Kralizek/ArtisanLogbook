import { useEffect, useState } from "react";
import { operationsClient } from "./clients";
import { OperationalError } from "./status";
import type { components, paths } from "./generated";

export type Management = {
  monitoring: components["schemas"]["MonitoringStatus"];
  imports: components["schemas"]["ImportOperation"][];
  discovery: paths["/api/v1/sources"]["get"]["responses"][200]["content"]["application/json"];
  installation: components["schemas"]["InstallationSelection"];
};

export function clientName(folder: string): string {
  const known: Record<string, string> = {
    _retail_: "Retail",
    _forever_: "Forever",
    _classic_: "Classic",
    _classic_era_: "Classic Era",
  };
  return (
    known[folder.toLowerCase()] ??
    (/^[a-z0-9_-]{1,40}$/i.test(folder)
      ? `Unknown client (${folder})`
      : "Unrecognized client")
  );
}

export function useManagement() {
  const [data, setData] = useState<Management>();
  const [error, setError] = useState<Error>();
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout>;
    async function read() {
      try {
        const [monitoring, imports, sources, installation] = await Promise.all([
          operationsClient.GET("/api/v1/monitoring", {
            signal: controller.signal,
          }),
          operationsClient.GET("/api/v1/imports", {
            params: { query: { limit: 100 } },
            signal: controller.signal,
          }),
          operationsClient.GET("/api/v1/sources", {
            signal: controller.signal,
          }),
          operationsClient.GET("/api/v1/installations", {
            signal: controller.signal,
          }),
        ]);
        if (controller.signal.aborted) return;
        if (monitoring.error)
          throw new OperationalError(
            monitoring.response.status,
            monitoring.error,
          );
        if (imports.error)
          throw new OperationalError(imports.response.status, imports.error);
        if (sources.error)
          throw new OperationalError(sources.response.status, sources.error);
        if (installation.error)
          throw new OperationalError(
            installation.response.status,
            installation.error,
          );
        if (
          !monitoring.data ||
          !imports.data ||
          !sources.data ||
          !installation.data
        )
          throw new Error("Management data was not returned.");
        setData({
          monitoring: monitoring.data,
          imports: imports.data.operations,
          discovery: sources.data,
          installation: installation.data,
        });
        setError(undefined);
      } catch (failure) {
        if (!controller.signal.aborted)
          setError(
            failure instanceof Error
              ? failure
              : new Error("Management unavailable."),
          );
      } finally {
        if (!controller.signal.aborted)
          timer = setTimeout(() => {
            if (document.visibilityState === "hidden") {
              timer = setTimeout(read, 15_000);
            } else void read();
          }, 15_000);
      }
    }
    void read();
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [revision]);
  return { data, error, retry: () => setRevision((value) => value + 1) };
}
