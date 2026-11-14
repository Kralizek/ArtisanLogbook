import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useStatus, type CompanionStatus } from "./status";

const get = vi.hoisted(() => vi.fn());
vi.mock("./clients", () => ({ operationsClient: { GET: get } }));

function response(count: number) {
  const data: CompanionStatus = {
    applicationVersion: "test",
    state: "Running",
    database: { available: true, schemaVersion: 1 },
    history: { craftCount: count, gameContexts: [] },
  };
  return { data, response: new Response() };
}

async function advance(milliseconds: number) {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(milliseconds);
  });
}

let visible = true;
beforeEach(() => {
  vi.useFakeTimers();
  get.mockReset();
  visible = true;
  vi.spyOn(document, "visibilityState", "get").mockImplementation(() =>
    visible ? "visible" : "hidden",
  );
});
afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
});

describe("operational status refresh", () => {
  it("refreshes visible status every 30 seconds and clears recovered errors", async () => {
    get
      .mockResolvedValueOnce(response(1))
      .mockRejectedValueOnce(new TypeError("Companion unavailable"))
      .mockResolvedValue(response(3));
    const { result } = renderHook(() => useStatus());
    await advance(0);
    expect(result.current.status?.history?.craftCount).toBe(1);
    await advance(29_999);
    expect(get).toHaveBeenCalledTimes(1);
    await advance(1);
    expect(result.current.error).toBeInstanceOf(TypeError);
    await advance(30_000);
    expect(result.current.status?.history?.craftCount).toBe(3);
    expect(result.current.error).toBeUndefined();
    expect(result.current.loading).toBe(false);
  });

  it("pauses while hidden and refreshes immediately on return", async () => {
    get.mockResolvedValueOnce(response(1)).mockResolvedValue(response(2));
    const { result } = renderHook(() => useStatus());
    await advance(0);
    visible = false;
    act(() => document.dispatchEvent(new Event("visibilitychange")));
    await advance(90_000);
    expect(get).toHaveBeenCalledTimes(1);
    visible = true;
    act(() => document.dispatchEvent(new Event("visibilitychange")));
    await advance(0);
    expect(result.current.status?.history?.craftCount).toBe(2);
    expect(get).toHaveBeenCalledTimes(2);
  });

  it("never overlaps polling, cancels replaced requests and ignores their late results", async () => {
    let complete!: (value: ReturnType<typeof response>) => void;
    const pending = new Promise<ReturnType<typeof response>>((resolve) => {
      complete = resolve;
    });
    get.mockReturnValueOnce(pending).mockResolvedValue(response(2));
    const { result, unmount } = renderHook(() => useStatus());
    const originalSignal: AbortSignal = get.mock.calls[0][1].signal;
    await advance(90_000);
    act(() => document.dispatchEvent(new Event("visibilitychange")));
    expect(get).toHaveBeenCalledTimes(1);
    act(() => result.current.retry());
    await advance(0);
    expect(originalSignal.aborted).toBe(true);
    expect(result.current.status?.history?.craftCount).toBe(2);
    await act(async () => {
      complete(response(1));
    });
    expect(result.current.status?.history?.craftCount).toBe(2);
    const currentSignal: AbortSignal = get.mock.calls[1][1].signal;
    unmount();
    expect(currentSignal.aborted).toBe(true);
    await advance(90_000);
    expect(get).toHaveBeenCalledTimes(2);
  });
});
