// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { createDemoAdapter } from "../adapters/demo";
import { UnsupportedOperationError, type DataAdapter } from "../adapter";
import { BridgeProvider, useUpdate, type UpdateHook, type UpdateState } from "../index";
import type { HostEvent } from "../protocol";
import { noCore, tick } from "./testCore";

afterEach(cleanup);

function mount(adapter: DataAdapter) {
  const hook = {} as { current: UpdateHook };
  function Probe() {
    hook.current = useUpdate();
    return null;
  }
  render(
    <BridgeProvider adapter={adapter} core={noCore}>
      <Probe />
    </BridgeProvider>,
  );
  return hook;
}

const available: Partial<UpdateState> = {
  status: "available",
  version: "0.9.3",
  notesUrl: "https://github.com/trycua/cua/releases/tag/cua-spaces-v0.9.3",
  instructions: "Update by pulling the repository and rebuilding: git pull && pnpm --dir apps/cua-spaces tauri build",
};

describe("the update state (update.get, update.changed)", () => {
  it("reads the newer release the host found", async () => {
    const hook = mount(createDemoAdapter({ latencyMs: 0, update: available }));
    await waitFor(() => expect(hook.current.data?.state).toMatchObject({ status: "available", version: "0.9.3" }));
    expect(hook.current.data?.state.instructions).toContain("git pull");
  });

  it("asks again when the host says its updater moved on", async () => {
    let state: UpdateState = { status: "checking", currentVersion: "0.9.2", version: null, notesUrl: null, message: null };
    const demo = createDemoAdapter({ latencyMs: 0 });
    let push: (e: HostEvent) => void = () => {};
    const adapter: DataAdapter = {
      ...demo,
      call: (op, args) => (op === "update.get" ? Promise.resolve({ ...state }) : demo.call(op, args)),
      subscribe: (listener) => {
        push = listener;
        return demo.subscribe(listener);
      },
    } as DataAdapter;
    const hook = mount(adapter);
    await waitFor(() => expect(hook.current.data?.state.status).toBe("checking"));
    state = { ...state, status: "available", version: "0.9.3" };
    // The page is told; it does not poll every moment.
    await tick(30);
    expect(hook.current.data?.state.status).toBe("checking");
    push({ type: "update.changed" });
    await waitFor(() => expect(hook.current.data?.state).toMatchObject({ status: "available", version: "0.9.3" }));
  });

  it("is unsupported on a host with no updater (Tauri)", async () => {
    const demo = createDemoAdapter({ latencyMs: 0 });
    const adapter: DataAdapter = { ...demo, call: (op, args) => (op === "update.get" ? Promise.reject(new UnsupportedOperationError("tauri", "update.get")) : demo.call(op, args)) } as DataAdapter;
    const hook = mount(adapter);
    await waitFor(() => expect(hook.current.unsupported).toBe(true));
    expect(hook.current.data).toBeUndefined();
  });
});
