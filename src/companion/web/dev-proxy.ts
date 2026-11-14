import type { IncomingMessage } from "node:http";
import type { Plugin } from "vite";

export function isLocalRequest(request: IncomingMessage): boolean {
  const host = request.headers.host;
  if (
    !host ||
    !/^(127\.0\.0\.1|localhost)(?::\d{1,5})?$/i.test(host) ||
    !URL.canParse(`http://${host}`)
  )
    return false;
  const url = new URL(`http://${host}`);
  if (!["127.0.0.1", "localhost"].includes(url.hostname)) return false;
  const site = request.headers["sec-fetch-site"];
  if (site && site !== "same-origin" && site !== "none") return false;
  const origin = request.headers.origin;
  return !origin || origin === url.origin;
}

export function localApiProxy(companionUrl: string | undefined): Plugin {
  if (companionUrl) {
    const target = new URL(companionUrl);
    if (target.protocol !== "http:" || target.hostname !== "127.0.0.1") {
      throw new Error("COMPANION_URL must be an HTTP IPv4 loopback endpoint.");
    }
  }
  return {
    name: "companion-local-proxy",
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        if (!isLocalRequest(request)) {
          response.writeHead(403, { "Content-Type": "text/plain" });
          response.end("Cross-origin development requests are not allowed.");
          return;
        }
        if (/^\/(?:graphql(?:\?|$)|api(?:\/|\?|$))/.test(request.url ?? "")) {
          if (!companionUrl) {
            response.writeHead(503, { "Content-Type": "text/plain" });
            response.end(
              "Start Aspire or set COMPANION_URL to the local Companion endpoint.",
            );
            return;
          }
          // Rewrite only after validating the original browser origin and fetch metadata.
          if (request.headers.origin)
            request.headers.origin = new URL(companionUrl).origin;
          if (request.headers["sec-fetch-site"])
            request.headers["sec-fetch-site"] = "same-origin";
        }
        next();
      });
    },
  };
}
