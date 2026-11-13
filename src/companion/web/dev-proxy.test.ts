import type { IncomingMessage } from "node:http";
import { describe, expect, it } from "vitest";
import { isLocalRequest, localApiProxy } from "./dev-proxy";

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
});
