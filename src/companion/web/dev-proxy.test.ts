import type { IncomingMessage } from "node:http";
import { describe, expect, it } from "vitest";
import { isLocalRequest, localApiProxy } from "./dev-proxy";
import { isBrowserRoute } from "./browser-routes";

function request(headers: IncomingMessage["headers"]) {
  return { headers } as IncomingMessage;
}

describe("development proxy trust boundary", () => {
  it("allows the browser's original same-origin request", () => {
    expect(
      isLocalRequest(
        request({
          host: "127.0.0.1:5173",
          origin: "http://127.0.0.1:5173",
          "sec-fetch-site": "same-origin",
        }),
      ),
    ).toBe(true);
  });
  it.each([
    { host: "attacker.example:5173" },
    { host: "127.0.0.1:5173", origin: "http://attacker.example" },
    { host: "127.0.0.1:5173", origin: "null" },
    { host: "127.0.0.1:5173", "sec-fetch-site": "cross-site" },
    { host: "127.0.0.1:5173", "sec-fetch-site": "same-site" },
    { host: "malformed%host" },
  ])("rejects untrusted incoming headers %j", (headers) => {
    expect(isLocalRequest(request(headers))).toBe(false);
  });
  it("refuses a non-loopback upstream", () => {
    expect(() => localApiProxy("http://example.com")).toThrow("loopback");
  });
  const navigation = {
    method: "GET",
    url: "/",
    headers: {
      host: "localhost:5173",
      "sec-fetch-site": "same-site",
      "sec-fetch-mode": "navigate",
      "sec-fetch-dest": "document",
      "sec-fetch-user": "?1",
    },
  };
  it.each(["same-site", "cross-site"])(
    "allows a user to open the SPA from a %s dashboard link",
    (site) => {
      expect(
        isLocalRequest({
          ...navigation,
          headers: { ...navigation.headers, "sec-fetch-site": site },
        } as IncomingMessage),
      ).toBe(true);
    },
  );
  it.each(["/api/v1/status", "/graphql", "/assets/index.js"])(
    "does not relax fetch metadata for navigation to %s",
    (url) => {
      expect(isLocalRequest({ ...navigation, url } as IncomingMessage)).toBe(
        false,
      );
    },
  );
  it.each([
    "/retail/activity",
    "/forever/items/opaque?period=90",
    "/18-Hardcore/recipes/opaque",
    "/companion",
  ])("allows normal browser navigation to analytical route %s", (url) => {
    expect(isLocalRequest({ ...navigation, url } as IncomingMessage)).toBe(
      true,
    );
  });
  it.each([
    "/retail/items/missing.js",
    "/api/v1/status",
    "/assets/missing.js",
    "/unknown-page",
  ])("does not classify %s as a browser route", (url) =>
    expect(isBrowserRoute(url)).toBe(false),
  );
  it("still rejects an untrusted origin on document navigation", () => {
    expect(
      isLocalRequest({
        ...navigation,
        headers: { ...navigation.headers, origin: "http://attacker.example" },
      } as IncomingMessage),
    ).toBe(false);
  });
  it("does not allow cross-port background fetches of the SPA", () => {
    expect(
      isLocalRequest({
        ...navigation,
        headers: { ...navigation.headers, "sec-fetch-mode": "cors" },
      } as IncomingMessage),
    ).toBe(false);
  });
  it("does not allow a cross-port POST to the SPA", () => {
    expect(
      isLocalRequest({ ...navigation, method: "POST" } as IncomingMessage),
    ).toBe(false);
  });
});
