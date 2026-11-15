export function isBrowserRoute(path: string): boolean {
  return (
    ["/", "/history", "/history/", "/companion", "/companion/"].includes(
      path,
    ) ||
    /^\/saved\/[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\/?$/i.test(path) ||
    /^\/(?:retail|forever|[1-9]\d*(?:-[^/]+)?)\/(?:activity|library|crafts)\/?$/.test(
      path,
    ) ||
    /^\/(?:retail|forever|[1-9]\d*(?:-[^/]+)?)\/(?:recipes|items|crafts)\/[a-zA-Z0-9_-]+\/?$/.test(
      path,
    )
  );
}
