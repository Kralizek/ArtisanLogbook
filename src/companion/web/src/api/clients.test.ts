import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import { RecentCraftsDocument } from "../graphql/generated/graphql";

const transport = vi.fn<typeof fetch>();
let clients: typeof import("./clients");
let status: typeof import("./status");

beforeAll(async () => {
  const NativeRequest = globalThis.Request;
  class BrowserRequest extends NativeRequest {
    constructor(input: RequestInfo | URL, init?: RequestInit) {
      super(
        typeof input === "string" ? new URL(input, "http://localhost") : input,
        init,
      );
    }
  }
  vi.stubGlobal("Request", BrowserRequest);
  vi.stubGlobal("fetch", transport);
  clients = await import("./clients");
  status = await import("./status");
});
beforeEach(() => transport.mockReset());
afterAll(() => vi.unstubAllGlobals());

describe("API transports", () => {
  it("uses relative URLs, POST GraphQL and the same client header for both contracts", async () => {
    transport.mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            data: {
              crafts: {
                nodes: [],
                pageInfo: { hasNextPage: false, endCursor: null },
              },
            },
          }),
          { headers: { "Content-Type": "application/json" } },
        ),
    );
    const { historyClient, operationsClient } = clients;
    await historyClient.query({ query: RecentCraftsDocument });
    expect(transport.mock.calls[0][0]).toBe("/graphql");
    const options = transport.mock.calls[0][1];
    expect(options?.method).toBe("POST");
    expect(new Headers(options?.headers).get("X-Artisan-Logbook-Client")).toBe(
      "web",
    );
    transport.mockImplementation(
      async () =>
        new Response("{}", { headers: { "Content-Type": "application/json" } }),
    );
    await operationsClient.GET("/api/v1/health");
    const request = transport.mock.calls.at(-1)?.[0];
    expect(request).toBeInstanceOf(Request);
    if (!(request instanceof Request))
      throw new Error("Expected an operational Request.");
    expect(request.url).toContain("/api/v1/health");
    expect(request.headers.get("X-Artisan-Logbook-Client")).toBe("web");
  });

  it("preserves problem response status and browser cancellation", async () => {
    transport.mockResolvedValue(
      new Response(
        JSON.stringify({
          title: "Forbidden",
          status: 403,
          code: "origin-not-allowed",
        }),
        {
          status: 403,
          headers: { "Content-Type": "application/problem+json" },
        },
      ),
    );
    const { readStatus } = status;
    const controller = new AbortController();
    await expect(readStatus(controller.signal)).rejects.toMatchObject({
      status: 403,
      problem: { code: "origin-not-allowed" },
    });
    const request = transport.mock.calls[0][0];
    if (!(request instanceof Request))
      throw new Error("Expected an operational Request.");
    controller.abort();
    expect(request.signal.aborted).toBe(true);
  });
});
